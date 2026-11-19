-- ADAddOn: add-on for AutoDrive (requires FS25_AutoDrive)
-- Author: PropaineX
--
-- A green bar on top of the AutoDrive HUD with an ON/OFF push button and a mode menu. While a vehicle's button is ON
-- and it runs AutoDrive "Pickup and Deliver" (pickup = 1st target, deliver = 2nd target), the selected mode runs:
--   * Fill Robot: 2nd target = a pin at the barn to fill; ADAddOn picks bin, feed and storage and sets the 1st target
--     itself (see the "Fill feeding robot mode" section). Without an AutoDrive target over any robot tipping point it tops off
--     the 2nd target with the selected feed instead: exactly what it still takes, the last load only what's missing.
--   * Milk Transport: every milk type the 1st target has (cow, buffalo, goat, mod milks) to the 2nd target, one type
--     per load, then it stops and says it's done.
--   * Bale Collection: 1st target = the field's pin, 2nd target = where the bales go. AutoDrive's Courseplay helper is
--     switched on, so Courseplay collects, AutoDrive delivers each full load and hands back to Courseplay at the field
--     until the field is clear.
--   * Top It Off: the selected fill type from the 1st target (loading point) to the 2nd target (the tip) until the tip
--     is full: each load only what the tip still takes, so it never overfills; then it stops and says it's done.
-- The work runs on the server; the button is synced by ADAddOnSpec.lua.

ADAddOn = {}
ADAddOn.modName = g_currentModName
ADAddOn.modDir = g_currentModDirectory

-- ignore amounts below this (liters)
ADAddOn.MIN_AMOUNT = 1
-- no trip for a source with less than this share of the vehicle's capacity (a source that keeps producing)
ADAddOn.MIN_TRIP_SHARE = 0.015
-- Top It Off / Milk: no trip for less than this share of what the target holds (user's rule 2026-11-07: every
-- target ends 95 % full or more, never over 100 %), but never more than a full vehicle
ADAddOn.MIN_TARGET_SHARE = 0.05
-- Top It Off / Milk: the source is collected down to this many liters (user's rule 2026-11-09); the share rules above
-- only decide whether the destination has room worth a trip
ADAddOn.MIN_SOURCE = 250
-- how far around a target marker a storage / unload point may be: the marker sits a train length past it
ADAddOn.SEARCH_EXTRA = 30
-- the bar is a quarter inch tall (24 px at 96 dpi), scaled like the AutoDrive HUD
ADAddOn.BAR_HEIGHT_PX = 24
ADAddOn.BUTTON_ASPECT = 256 / 208
ADAddOn.MESSAGE_TIME = 10000
-- the mode menu on the bar, in the order of ADAddOnSpec.MODE_*
-- (indexed by mode number; the menu shows them in MODE_ORDER)
ADAddOn.MODE_NAMES = {"Fill Robot $$$", "Milk Transport", "Bale Collection", "Top It Off", "Fill Robot - In Stock", "Refuel/Repair"}
ADAddOn.MODE_ORDER = {5, 1, 2, 3, 4, 6}
-- at the destination with load left and no room left for this long: stop instead of waiting forever
ADAddOn.FULL_WAIT = 5000

local function getSpec(vehicle)
    return vehicle ~= nil and vehicle[ADAddOnSpec.SPEC_TABLE_NAME] or nil
end

function ADAddOn.isOn(vehicle)
    local spec = getSpec(vehicle)
    return spec ~= nil and spec.isOn
end

-- is the unload target at a place the vehicle's farm owns? The unloading station nearest to the 2nd target
-- (within 60 m, like best price) decides; no station near it counts as own, so best price stays off
ADAddOn.OWN_TARGET_DISTANCE = 60
function ADAddOn.isOwnTarget(vehicle)
    local AD = ADAddOn.AD
    local marker = vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule:getSecondMarker() or nil
    local wayPoint = marker ~= nil and marker.id ~= nil and AD.ADGraphManager:getWayPointById(marker.id) or nil
    if wayPoint == nil or g_currentMission == nil or g_currentMission.storageSystem == nil then
        return true
    end
    local nearest, nearestDistance = nil, ADAddOn.OWN_TARGET_DISTANCE
    for _, station in pairs(g_currentMission.storageSystem:getUnloadingStations()) do
        local x, z = AD.ADBestPrice.getStationPosition(station)
        if x ~= nil then
            local distance = MathUtil.vector2Length(wayPoint.x - x, wayPoint.z - z)
            if distance <= nearestDistance then
                nearest, nearestDistance = station, distance
            end
        end
    end
    if nearest == nil then
        return true
    end
    local placeable = nearest.owningPlaceable
    local owner = placeable ~= nil and placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or nil
    local own = owner ~= nil and owner == vehicle:getOwnerFarmId()
    local key = tostring(marker.id) .. (own and ":own" or ":sell")
    if vehicle.adAddOnOwnTargetKey ~= key then
        vehicle.adAddOnOwnTargetKey = key
        ADAddOn.log(vehicle, "best price: target '%s' is %s ('%s', %d m)", tostring(marker.name),
            own and "own (Top It Off, best price off)" or "a seller (best price allowed)", ADAddOn.nameOf(placeable), math.floor(nearestDistance))
    end
    return own
end

function ADAddOn:loadMap(name)
    -- AutoDrive lives in its own mod environment
    ADAddOn.AD = FS25_AutoDrive
    if ADAddOn.AD == nil or ADAddOn.AD.AutoDrive == nil then
        Logging.error("[ADAddOn] FS25_AutoDrive not found, add-on disabled")
        return
    end

    local AD = ADAddOn.AD
    local ok = true
    for _, className in ipairs({"AutoDrive", "AutoDriveHud", "PickupAndDeliverMode", "LoadAtDestinationTask", "StopAndDisableADTask",
        "ADTaskModule", "ADStateModule", "ADGraphManager", "ADTriggerManager", "ADMessagesManager", "AutoDriveMessageEvent"}) do
        if AD[className] == nil then
            Logging.error("[ADAddOn] AutoDrive class '%s' not found, add-on disabled", className)
            ok = false
        end
    end
    if not ok then
        return
    end

    -- add-on button on: best price is off when the unload target is a place the farm owns (its production, BGA,
    -- silo): Top It Off fills it. A selling point the farm doesn't own keeps AutoDrive's best price setting.
    if AD.ADBestPrice ~= nil and AD.ADBestPrice.getMode ~= nil then
        AD.ADBestPrice.getMode = Utils.overwrittenFunction(AD.ADBestPrice.getMode, function(vehicle, superFunc)
            if ADAddOn.isOn(vehicle) and ADAddOn.isOwnTarget(vehicle) then
                return AD.ADBestPrice.OFF
            end
            return superFunc(vehicle)
        end)
    end

    -- HUD bar
    AD.AutoDriveHud.drawHud = Utils.appendedFunction(AD.AutoDriveHud.drawHud, ADAddOn.drawHud)
    AD.AutoDriveHud.mouseEventOnHudElements = Utils.overwrittenFunction(AD.AutoDriveHud.mouseEventOnHudElements, ADAddOn.mouseEventOnHudElements)
    AD.AutoDriveHud.isMouseOverHud = Utils.overwrittenFunction(AD.AutoDriveHud.isMouseOverHud, ADAddOn.isMouseOverHud)

    -- the work
    AD.PickupAndDeliverMode.start = Utils.prependedFunction(AD.PickupAndDeliverMode.start, ADAddOn.onPickupAndDeliverStart)
    AD.PickupAndDeliverMode.getNextTask = Utils.overwrittenFunction(AD.PickupAndDeliverMode.getNextTask, ADAddOn.getNextTask)
    AD.LoadAtDestinationTask.update = Utils.overwrittenFunction(AD.LoadAtDestinationTask.update, ADAddOn.loadTaskUpdate)
    LoadTrigger.update = Utils.overwrittenFunction(LoadTrigger.update, ADAddOn.loadTriggerUpdate)
    if AD.AutoDrive.passToExternalMod_CP ~= nil then
        AD.AutoDrive.passToExternalMod_CP = Utils.prependedFunction(AD.AutoDrive.passToExternalMod_CP, ADAddOn.beforePassToCp)
    end
    -- AutoDrive starts Courseplay with startCpAtLastWp, which runs Courseplay's field work first when a course is loaded
    if AD.AutoDrive.StartCP ~= nil and AD.AutoDrive.RestartCP ~= nil then
        AD.AutoDrive.StartCP = Utils.overwrittenFunction(AD.AutoDrive.StartCP, ADAddOn.startCp)
        AD.AutoDrive.RestartCP = Utils.overwrittenFunction(AD.AutoDrive.RestartCP, ADAddOn.startCp)
    else
        Logging.warning("[ADAddOn] AutoDrive's StartCP / RestartCP not found: Courseplay may start field work instead of collecting bales")
    end
    -- Courseplay 8.1 never raises onCpFinished, so "no bales left" is taken from Courseplay's bale job itself
    local CP = FS25_Courseplay
    if CP ~= nil and CP.AIDriveStrategyFindBales ~= nil and CP.AIDriveStrategyFindBales.finishJob ~= nil then
        CP.AIDriveStrategyFindBales.finishJob = Utils.prependedFunction(CP.AIDriveStrategyFindBales.finishJob, ADAddOn.onBaleJobFinish)
    else
        Logging.warning("[ADAddOn] Courseplay's AIDriveStrategyFindBales.finishJob not found: no \"no bales left\" message")
    end
    if AD.ADTrailerModule ~= nil then
        AD.ADTrailerModule.startUnloadingIntoTrigger = Utils.appendedFunction(AD.ADTrailerModule.startUnloadingIntoTrigger, ADAddOn.onStartUnloading)
        AD.ADTrailerModule.updateLoad = Utils.overwrittenFunction(AD.ADTrailerModule.updateLoad, ADAddOn.trailerUpdateLoad)
        if AD.ADTrailerModule.lookForPossibleUnloadTrigger ~= nil then
            AD.ADTrailerModule.lookForPossibleUnloadTrigger = Utils.overwrittenFunction(AD.ADTrailerModule.lookForPossibleUnloadTrigger, ADAddOn.lookForPossibleUnloadTrigger)
        else
            Logging.warning("[ADAddOn] AutoDrive's ADTrailerModule.lookForPossibleUnloadTrigger not found: robot runs can't refuse other tipping points")
        end
    end
    if AD.UnloadAtDestinationTask ~= nil then
        AD.UnloadAtDestinationTask.update = Utils.overwrittenFunction(AD.UnloadAtDestinationTask.update, ADAddOn.unloadTaskUpdate)
    end

    if g_dedicatedServer == nil then
        ADAddOn.barOverlay = Overlay.new(g_baseUIFilename, 0, 0, 1, 1)
        ADAddOn.barOverlay:setUVs(g_colorBgUVs)
        ADAddOn.buttonOffOverlay = Overlay.new(Utils.getFilename("textures/button_off.dds", ADAddOn.modDir), 0, 0, 1, 1)
        ADAddOn.buttonOnOverlay = Overlay.new(Utils.getFilename("textures/button_on.dds", ADAddOn.modDir), 0, 0, 1, 1)
        ADAddOn.arrowDownOverlay = Overlay.new(Utils.getFilename("textures/arrow_down.dds", ADAddOn.modDir), 0, 0, 1, 1)
        ADAddOn.arrowUpOverlay = Overlay.new(Utils.getFilename("textures/arrow_up.dds", ADAddOn.modDir), 0, 0, 1, 1)
    end

    -- Repair/Refill: AutoDrive's own repair / refuel trips, at the sites ADAddOn picks
    ADAddOn.installRepairRefillHooks()

    -- the button (ADAddOnSpec.lua) reaches the server side work through this
    ADAddOnSpec.onSwitchedCallback = ADAddOn.onSwitched
    ADAddOnSpec.onModeChangedCallback = ADAddOn.onModeChanged

    ADAddOn.isReady = true
    Logging.info("[ADAddOn] loaded, AutoDrive hooks installed")
end

function ADAddOn:deleteMap()
    for _, name in ipairs({"barOverlay", "buttonOffOverlay", "buttonOnOverlay", "arrowDownOverlay", "arrowUpOverlay"}) do
        if ADAddOn[name] ~= nil then
            ADAddOn[name]:delete()
            ADAddOn[name] = nil
        end
    end
    ADAddOn.isReady = false
end

------------------------------------------------------------------------------------------------------------------------
-- HUD: green bar on top of the AutoDrive window, button on the left, "ADAddOn" on the right
------------------------------------------------------------------------------------------------------------------------

-- returns x, y, width, height of the bar and x, y, width, height of the button (normalized screen values)
function ADAddOn.getBarLayout(hud)
    if hud == nil or hud.hudElements == nil or hud.posX == nil or hud.width == nil then
        return nil
    end
    local header = nil
    for _, element in ipairs(hud.hudElements) do
        if element.name == "header" then
            header = element
            break
        end
    end
    if header == nil then
        return nil
    end

    local AutoDrive = ADAddOn.AD.AutoDrive
    local uiScale = g_gameSettings:getValue("uiScale")
    if AutoDrive.getSetting("guiScale") ~= 0 then
        uiScale = AutoDrive.getSetting("guiScale")
    end

    -- sit on the green header exactly as AutoDrive drew it this frame: it grows upwards when its text wraps onto more
    -- lines or the tips are shown, and gets wider / narrower with the window (wide HUD, editor buttons, GUI scale)
    local barX, barY, barWidth = hud.posX, nil, hud.width
    local ov = header.ov
    if ov ~= nil and ov.y ~= nil and ov.height ~= nil and ov.width ~= nil then
        barX, barY, barWidth = ov.x, ov.y + ov.height, ov.width
    else
        barY = header.position.y + header.size.height + (header.extraHeight or 0)
    end
    local _, barHeight = getNormalizedScreenValues(0, ADAddOn.BAR_HEIGHT_PX * uiScale)
    local gapX, gapY = getNormalizedScreenValues(2 * uiScale, 2 * uiScale)

    local buttonHeight = barHeight - 2 * gapY
    local buttonWidth = buttonHeight * ADAddOn.BUTTON_ASPECT * g_screenHeight / g_screenWidth
    return barX, barY, barWidth, barHeight, barX + gapX / 2, barY + gapY, buttonWidth, buttonHeight, gapX
end

local function getMode(vehicle)
    local spec = getSpec(vehicle)
    return spec ~= nil and spec.mode or ADAddOnSpec.MODE_FILL_ROBOT
end

-- the mode box between the button and the name, and its list (one row per mode, opening downwards over the header):
-- x, y, width, height of the box, the font size, the row height
function ADAddOn.getModeLayout(hud)
    local barX, barY, barWidth, barHeight, buttonX, buttonY, buttonWidth, buttonHeight, gapX = ADAddOn.getBarLayout(hud)
    if barX == nil then
        return nil
    end
    local fontSize = barHeight * 0.55
    setTextBold(true)
    local textWidth = 0
    for _, name in ipairs(ADAddOn.MODE_NAMES) do
        textWidth = math.max(textWidth, getTextWidth(fontSize, name))
    end
    setTextBold(false)
    local arrowWidth = buttonHeight * 0.5 * g_screenHeight / g_screenWidth
    local boxX = buttonX + buttonWidth + 3 * gapX
    local boxWidth = textWidth + arrowWidth + 6 * gapX
    return boxX, buttonY, boxWidth, buttonHeight, fontSize, barHeight, gapX, arrowWidth
end

-- the open list's rows: row i is at y = barY - i * rowHeight
local function getModeRow(hud, i)
    local boxX, boxY, boxWidth, boxHeight, fontSize, rowHeight = ADAddOn.getModeLayout(hud)
    local _, barY = ADAddOn.getBarLayout(hud)
    return boxX, barY - i * rowHeight, boxWidth, rowHeight, fontSize
end

local function drawModeBox(hud, vehicle)
    local boxX, boxY, boxWidth, boxHeight, fontSize, _, gapX, arrowWidth = ADAddOn.getModeLayout(hud)
    if boxX == nil then
        return
    end
    local r, g, b = unpack(ADAddOn.AD.AutoDrive.currentColors.ad_color_header)
    drawFilledRect(boxX, boxY, boxWidth, boxHeight, r * 0.55, g * 0.55, b * 0.55, 1)
    local textHeight = getTextHeight(fontSize, "Ag")
    setTextBold(true)
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
    renderText(boxX + 2 * gapX, boxY + (boxHeight - textHeight) / 2, fontSize, ADAddOn.MODE_NAMES[getMode(vehicle)] or "?")
    setTextBold(false)
    local arrow = ADAddOn.modeListOpen and ADAddOn.arrowUpOverlay or ADAddOn.arrowDownOverlay
    if arrow ~= nil then
        local arrowHeight = boxHeight * 0.5
        arrow:setPosition(boxX + boxWidth - arrowWidth - 2 * gapX, boxY + (boxHeight - arrowHeight) / 2)
        arrow:setDimension(arrowWidth, arrowHeight)
        arrow:setColor(1, 1, 1, 1)
        arrow:render()
    end
end

-- the open mode list, on top of everything else of the HUD
local function drawModeList(hud, vehicle)
    if not ADAddOn.modeListOpen then
        return
    end
    new2DLayer()
    local r, g, b = unpack(ADAddOn.AD.AutoDrive.currentColors.ad_color_header)
    local current = getMode(vehicle)
    for i, mode in ipairs(ADAddOn.MODE_ORDER) do
        local name = ADAddOn.MODE_NAMES[mode]
        local x, y, width, height, fontSize = getModeRow(hud, i)
        if mode == current then
            drawFilledRect(x, y, width, height, r * 0.5, g * 0.5, b * 0.5, 0.95)
        else
            drawFilledRect(x, y, width, height, 0.02, 0.02, 0.02, 0.92)
        end
        local textHeight = getTextHeight(fontSize, "Ag")
        local _, _, _, _, _, _, gapX = ADAddOn.getModeLayout(hud)
        setTextBold(true)
        if mode == current then
            setTextColor(math.min(1, r * 2.2), math.min(1, g * 2.2), math.min(1, b * 2.2 + 0.1), 1)
        else
            setTextColor(1, 1, 1, 1)
        end
        renderText(x + 2 * gapX, y + (height - textHeight) / 2, fontSize, name)
        setTextBold(false)
    end
    -- a thin header-coloured frame around the list
    local x, y, width = getModeRow(hud, #ADAddOn.MODE_NAMES)
    local _, _, _, rowHeight = getModeRow(hud, 1)
    local listHeight = rowHeight * #ADAddOn.MODE_NAMES
    local lineX, lineY = getNormalizedScreenValues(1, 1)
    drawFilledRect(x, y, width, lineY, r, g, b, 1)
    drawFilledRect(x, y, lineX, listHeight, r, g, b, 1)
    drawFilledRect(x + width - lineX, y, lineX, listHeight, r, g, b, 1)
    setTextColor(1, 1, 1, 1)
end

function ADAddOn.drawHud(hud, vehicle)
    if not ADAddOn.isReady or ADAddOn.barOverlay == nil or vehicle == nil or getSpec(vehicle) == nil then
        return
    end
    local AutoDrive = ADAddOn.AD.AutoDrive
    -- same condition as AutoDriveHud:drawHud
    if not (vehicle == AutoDrive.getControlledVehicle() or AutoDrive.aiFrameOpen) then
        return
    end
    local barX, barY, barWidth, barHeight, buttonX, buttonY, buttonWidth, buttonHeight, gapX = ADAddOn.getBarLayout(hud)
    if barX == nil then
        return
    end

    local bar = ADAddOn.barOverlay
    bar:setPosition(barX, barY)
    bar:setDimension(barWidth, barHeight)
    bar:setColor(unpack(AutoDrive.currentColors.ad_color_header))
    bar:render()

    local button = ADAddOn.isOn(vehicle) and ADAddOn.buttonOnOverlay or ADAddOn.buttonOffOverlay
    button:setPosition(buttonX, buttonY)
    button:setDimension(buttonWidth, buttonHeight)
    button:setColor(1, 1, 1, 1)
    button:render()

    local fontSize = barHeight * 0.6
    local textHeight = getTextHeight(fontSize, "ADAddOn")
    setTextBold(true)
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_RIGHT)
    renderText(barX + barWidth - 3 * gapX, barY + (barHeight - textHeight) / 2, fontSize, "ADAddOn")
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)
    setTextColor(1, 1, 1, 1)

    drawModeBox(hud, vehicle)
    ADAddOn.redrawOpenList(hud, vehicle)
    drawModeList(hud, vehicle)
end

-- an open AutoDrive list (targets, fill types) pops up over the bar: draw it again on top, so the bar is behind it.
-- (Drawing the bar before AutoDrive instead would put AutoDrive's dark background over the bar's lower edge.)
function ADAddOn.redrawOpenList(hud, vehicle)
    local AD = ADAddOn.AD
    if (AD.AutoDrive.pullDownListExpanded or 0) == 0 or AD.ADPullDownList == nil then
        return
    end
    local uiScale = g_gameSettings:getValue("uiScale")
    if AD.AutoDrive.getSetting("guiScale") ~= 0 then
        uiScale = AD.AutoDrive.getSetting("guiScale")
    end
    for _, element in ipairs(hud.hudElements) do
        if element.state == AD.ADPullDownList.STATE_EXPANDED and element.onDraw ~= nil then
            new2DLayer()
            element:onDraw(vehicle, uiScale)
        end
    end
end

local function isInside(posX, posY, x, y, width, height)
    return x ~= nil and posX >= x and posX <= x + width and posY >= y and posY <= y + height
end

-- the mode of the row under the mouse when the list is open (nil = none)
local function getModeRowAt(hud, posX, posY)
    for i, mode in ipairs(ADAddOn.MODE_ORDER) do
        local x, y, width, height = getModeRow(hud, i)
        if isInside(posX, posY, x, y, width, height) then
            return mode
        end
    end
    return nil
end

function ADAddOn.mouseEventOnHudElements(hud, superFunc, vehicle, posX, posY, isDown, isUp, button)
    if ADAddOn.isReady and ADAddOn.modeListOpen and vehicle ~= nil and getSpec(vehicle) ~= nil then
        -- the open mode list gets every click: a row picks that mode, anywhere else closes the list
        if isDown or isUp then
            local row = getModeRowAt(hud, posX, posY)
            if isUp and button == 1 then
                if row ~= nil then
                    vehicle:setADAddOnMode(row)
                    ADAddOn.AD.AutoDrive.playSample(ADAddOn.AD.AutoDrive.mouseClickSample, 0.45)
                end
                ADAddOn.modeListOpen = false
            end
            if row ~= nil then
                return true
            end
            local boxX, boxY, boxWidth, boxHeight = ADAddOn.getModeLayout(hud)
            if isInside(posX, posY, boxX, boxY, boxWidth, boxHeight) then
                return true
            end
        end
    end
    -- an open AutoDrive list lies over the bar and gets the click
    if ADAddOn.isReady and vehicle ~= nil and getSpec(vehicle) ~= nil and not hud.isMoving
        and (ADAddOn.AD.AutoDrive.pullDownListExpanded or 0) == 0 then
        local barX, barY, barWidth, barHeight, buttonX, buttonY, buttonWidth, buttonHeight = ADAddOn.getBarLayout(hud)
        if isInside(posX, posY, barX, barY, barWidth, barHeight) then
            local boxX, boxY, boxWidth, boxHeight = ADAddOn.getModeLayout(hud)
            if button == 1 and isUp and isInside(posX, posY, buttonX, buttonY, buttonWidth, buttonHeight) then
                vehicle:setADAddOn(not vehicle:getIsADAddOnOn())
                ADAddOn.AD.AutoDrive.playSample(ADAddOn.AD.AutoDrive.mouseClickSample, 0.45)
            elseif button == 1 and isUp and isInside(posX, posY, boxX, boxY, boxWidth, boxHeight) then
                ADAddOn.modeListOpen = true
                ADAddOn.AD.AutoDrive.playSample(ADAddOn.AD.AutoDrive.mouseClickSample, 0.45)
            end
            -- the bar belongs to the HUD: clicks on it don't go to the world behind it
            return true
        end
    end
    return superFunc(hud, vehicle, posX, posY, isDown, isUp, button)
end

function ADAddOn.isMouseOverHud(hud, superFunc, x, y)
    if superFunc(hud, x, y) then
        return true
    end
    if ADAddOn.isReady and ADAddOn.AD.AutoDrive.getSetting("showHUD") then
        local vehicle = ADAddOn.AD.AutoDrive.getADFocusVehicle()
        if vehicle ~= nil and getSpec(vehicle) ~= nil then
            -- AutoDrive calls this on the class, the HUD itself is AutoDrive.Hud
            local barX, barY, barWidth, barHeight = ADAddOn.getBarLayout(ADAddOn.AD.AutoDrive.Hud)
            if isInside(x, y, barX, barY, barWidth, barHeight) then
                return true
            end
            if ADAddOn.modeListOpen and barX ~= nil and getModeRowAt(ADAddOn.AD.AutoDrive.Hud, x, y) ~= nil then
                return true
            end
        end
    end
    return false
end

------------------------------------------------------------------------------------------------------------------------
-- Fill levels
------------------------------------------------------------------------------------------------------------------------

-- liters of a fill type on the vehicle and everything attached to it
-- the vehicle's own tanks (fuel, DEF, air: Motorized consumers) are not cargo. A diesel truck counted its own fuel
-- tank as load, so it left the pickup with next to nothing (in game 2026-11-07: trips of 19 l diesel)
function ADAddOn.isConsumerFillUnit(v, index)
    local spec = v.spec_motorized
    if spec == nil or spec.consumersByFillType == nil then
        return false
    end
    for _, consumer in pairs(spec.consumersByFillType) do
        if consumer.fillUnitIndex == index then
            return true
        end
    end
    return false
end

function ADAddOn.getLoaded(vehicle, fillType)
    local total = 0
    for _, v in ipairs(vehicle:getChildVehicles()) do
        if v.spec_fillUnit ~= nil and v.getFillUnits ~= nil then
            for index, fillUnit in ipairs(v:getFillUnits()) do
                if fillUnit.fillType == fillType and not ADAddOn.isConsumerFillUnit(v, index) then
                    total = total + fillUnit.fillLevel
                end
            end
        end
    end
    return total
end

-- the fill types on board (any amount worth counting)
function ADAddOn.getAllLoadedTypes(vehicle)
    local list, seen = {}, {}
    for _, v in ipairs(vehicle:getChildVehicles()) do
        if v.spec_fillUnit ~= nil and v.getFillUnits ~= nil then
            for index, fillUnit in ipairs(v:getFillUnits()) do
                if fillUnit.fillLevel >= ADAddOn.MIN_AMOUNT and not ADAddOn.isConsumerFillUnit(v, index) and fillUnit.fillType ~= nil and fillUnit.fillType ~= FillType.UNKNOWN and not seen[fillUnit.fillType] then
                    seen[fillUnit.fillType] = true
                    table.insert(list, fillUnit.fillType)
                end
            end
        end
    end
    return list
end

-- liters of a fill type the vehicle can carry (fill units that hold it or are empty)
function ADAddOn.getCapacity(vehicle, fillType)
    local total = 0
    for _, v in ipairs(vehicle:getChildVehicles()) do
        if v.spec_fillUnit ~= nil and v.getFillUnits ~= nil then
            for index, fillUnit in ipairs(v:getFillUnits()) do
                if v:getFillUnitSupportsFillType(index, fillType) and not ADAddOn.isConsumerFillUnit(v, index)
                    and (fillUnit.fillType == fillType or fillUnit.fillLevel < 0.5 or fillUnit.fillType == FillType.UNKNOWN) then
                    total = total + fillUnit.capacity
                end
            end
        end
    end
    return total
end

function ADAddOn.getSourceLevel(trigger, fillType, farmId)
    if trigger == nil or trigger.source == nil or trigger.source.getAllFillLevels == nil then
        return 0
    end
    local fillLevels = trigger.source:getAllFillLevels(farmId)
    local level = fillLevels ~= nil and fillLevels[fillType] or 0
    if level < 0 then
        -- infinite source
        return math.huge
    end
    return level
end

-- unload trigger -> the feeding robot bin it belongs to (filled in by findRobotTrigger)
ADAddOn.robotBinOf = setmetatable({}, {__mode = "k"})

function ADAddOn.getFreeCapacity(unloadTrigger, fillType, farmId)
    if unloadTrigger == nil or unloadTrigger.target == nil then
        return 0
    end
    -- a feeding robot bin: its own capacity and fill level, the numbers the robot (and Farm Inventory) show
    local bin = ADAddOn.robotBinOf[unloadTrigger]
    if bin ~= nil and type(bin.capacity) == "number" and type(bin.fillLevel) == "number" then
        return math.max(0, bin.capacity - bin.fillLevel)
    end
    return math.max(0, unloadTrigger:getFillUnitFreeCapacity(1, fillType, farmId) or 0)
end

------------------------------------------------------------------------------------------------------------------------
-- Finding the source (pickup) and destination (deliver) at the AutoDrive targets
------------------------------------------------------------------------------------------------------------------------

local function getMarkerPosition(markerId)
    local wayPoint = ADAddOn.AD.ADGraphManager:getWayPointById(markerId)
    if wayPoint == nil then
        return nil
    end
    return wayPoint.x, wayPoint.z
end

local function getSearchRadius(vehicle)
    return ADAddOn.AD.AutoDrive.getTractorTrainLength(vehicle, true, false) + ADAddOn.SEARCH_EXTRA
end

-- closest load trigger (silo, barn milk, production output...) near the marker that has this fill type
function ADAddOn.findSource(vehicle, markerId, fillType, farmId)
    local markerX, markerZ = getMarkerPosition(markerId)
    if markerX == nil then
        return nil
    end
    local best, bestDistance = nil, getSearchRadius(vehicle)
    for _, trigger in pairs(ADAddOn.AD.ADTriggerManager.getLoadTriggers()) do
        -- fillTypes == nil means every type of the source (LoadTrigger:loadTriggerCallback); the game's own
        -- getIsFillTypeSupported would error on that, so check it here
        if trigger.source ~= nil and trigger.source.getAllFillLevels ~= nil and trigger.loadTriggerCallback ~= nil
            and (trigger.fillTypes == nil or trigger.fillTypes[fillType])
            and trigger.triggerNode ~= nil and entityExists(trigger.triggerNode) then
            local fillLevels = trigger.source:getAllFillLevels(farmId)
            if fillLevels ~= nil and fillLevels[fillType] ~= nil then
                local x, _, z = getWorldTranslation(trigger.triggerNode)
                local distance = MathUtil.vector2Length(x - markerX, z - markerZ)
                if distance < bestDistance then
                    best, bestDistance = trigger, distance
                end
            end
        end
    end
    return best
end

local function isUnloadTrigger(object)
    return object ~= nil and object.target ~= nil and object.exactFillRootNode ~= nil and object.getFillUnitFreeCapacity ~= nil
        and object.getFillUnitAllowsFillType ~= nil and object.isEnabled ~= false and entityExists(object.exactFillRootNode)
end

local function learnedKey(markerId, fillType)
    return tostring(markerId) .. ":" .. tostring(fillType)
end

-- where the tipping point of the trailer that carries this fill type is when AutoDrive stops at the marker: the
-- marker is where the tractor stops, the trailer tips a few meters back along the route (a robot barn has the robot's
-- spot and the barn's own trough next to each other; the one under the trailer is the one that gets the load)
function ADAddOn.getDischargePoint(vehicle, markerId, fillType)
    local graph = ADAddOn.AD.ADGraphManager
    local wayPoint = graph:getWayPointById(markerId)
    if wayPoint == nil then
        return nil
    end
    local back = 0
    local vx, _, vz = getWorldTranslation(vehicle.components[1].node)
    for _, v in ipairs(vehicle:getChildVehicles()) do
        if v ~= vehicle and v.getCurrentDischargeNode ~= nil and v.getFillUnitSupportsFillType ~= nil then
            local dischargeNode = v:getCurrentDischargeNode()
            if dischargeNode ~= nil and dischargeNode.node ~= nil and dischargeNode.fillUnitIndex ~= nil
                and v:getFillUnitSupportsFillType(dischargeNode.fillUnitIndex, fillType) then
                local dx, _, dz = getWorldTranslation(dischargeNode.node)
                back = MathUtil.vector2Length(dx - vx, dz - vz)
                break
            end
        end
    end

    -- walk back along the route into the marker
    local x, z = wayPoint.x, wayPoint.z
    local current = wayPoint
    for _ = 1, 100 do
        if back <= 0 or current.incoming == nil or current.incoming[1] == nil then
            break
        end
        local previous = graph:getWayPointById(current.incoming[1])
        if previous == nil then
            break
        end
        local segment = MathUtil.vector2Length(previous.x - current.x, previous.z - current.z)
        if segment >= back then
            local t = segment > 0 and back / segment or 0
            x, z = current.x + (previous.x - current.x) * t, current.z + (previous.z - current.z) * t
            break
        end
        back = back - segment
        current = previous
        x, z = current.x, current.z
    end
    return x, z
end

-- every unload trigger a barn's feeding robot has (its silage / straw / hay / mineral feed spots). The robot's own class
-- (FeedingRobot) is not in the game's Lua source, so its fields are searched instead of named: up to 5 levels deep, only
-- following plain tables, never back into the barn or the mission.
local SKIP_KEYS = {owningPlaceable = true, placeable = true, owner = true, husbandry = true, mission = true, target = true,
    parent = true, vehicle = true, __index = true}

local function collectUnloadTriggers(object, depth, found, visited)
    if depth > 5 or visited[object] or visited.count > 3000 then
        return
    end
    visited[object] = true
    visited.count = visited.count + 1
    for key, value in pairs(object) do
        if type(value) == "table" and not SKIP_KEYS[key] then
            if isUnloadTrigger(value) then
                found[value] = true
            else
                collectUnloadTriggers(value, depth + 1, found, visited)
            end
        end
    end
end

-- does this feeding robot bin take the fill type (same field checks as FS25_FarmInventory's getSpotFillType)
local function robotBinTakes(robot, binIndex, bin, fillType)
    local fillTypes = bin.fillTypes
    if type(fillTypes) == "table" then
        if fillTypes[fillType] then
            return true
        end
        for _, value in pairs(fillTypes) do
            if value == fillType then
                return true
            end
        end
    end
    if bin.fillTypeIndex == fillType or bin.fillType == fillType then
        return true
    end
    if type(robot.fillTypeToUnloadingSpot) == "table" then
        local target = robot.fillTypeToUnloadingSpot[fillType]
        if target ~= nil and (target == bin or target == binIndex) then
            return true
        end
    end
    return false
end

-- the feeding robot's bin for this fill type, at a barn with a robot near the marker: the robot's
-- unloadingSpots[i] (the bins Farm Inventory lists), and of that bin the tipping point nearest the trailer
function ADAddOn.findRobotTrigger(markerX, markerZ, radius, pointX, pointZ, fillType)
    local placeables = g_currentMission.placeableSystem ~= nil and g_currentMission.placeableSystem.placeables or nil
    if placeables == nil then
        return nil
    end
    local best, bestBin, bestDistance = nil, nil, math.huge
    local function consider(trigger, bin)
        if trigger:getFillUnitAllowsFillType(1, fillType) then
            local x, _, z = getWorldTranslation(trigger.exactFillRootNode)
            if MathUtil.vector2Length(x - markerX, z - markerZ) <= radius then
                local distance = MathUtil.vector2Length(x - pointX, z - pointZ)
                if distance < bestDistance then
                    best, bestBin, bestDistance = trigger, bin, distance
                end
            end
        end
    end
    for _, placeable in pairs(placeables) do
        local spec = placeable.spec_husbandryFeedingRobot
        local robot = spec ~= nil and spec.feedingRobot or nil
        if type(robot) == "table" then
            if type(robot.unloadingSpots) == "table" then
                for binIndex, bin in ipairs(robot.unloadingSpots) do
                    if type(bin) == "table" and robotBinTakes(robot, binIndex, bin, fillType) then
                        local found = {}
                        collectUnloadTriggers(bin, 1, found, {count = 0})
                        if next(found) == nil and not ADAddOn.loggedBinWithoutTriggers then
                            ADAddOn.loggedBinWithoutTriggers = true
                            local keys = {}
                            for key, value in pairs(bin) do
                                table.insert(keys, tostring(key) .. "=" .. type(value))
                            end
                            Logging.warning("[ADAddOn] feeding robot bin for fill type %s has no tipping points I can find, fields: %s",
                                tostring(fillType), table.concat(keys, ", "))
                        end
                        for trigger in pairs(found) do
                            ADAddOn.robotBinOf[trigger] = bin
                            consider(trigger, bin)
                        end
                    end
                end
            else
                -- a robot without the usual bin list: any of its unload points that take the fill type
                local found = {}
                collectUnloadTriggers(robot, 1, found, {count = 0})
                for trigger in pairs(found) do
                    consider(trigger, nil)
                end
            end
        end
    end
    return best, bestBin
end

-- the unload trigger (robot feeder spot, trough, silo, production input...) the trailer will tip into at the marker:
-- the one it really tipped into last time, else the feeding robot's spot when the marker is at a robot barn, else the
-- one closest to where the trailer's tipping point stops (noRobot: Top It Off, never the robot's storage)
function ADAddOn.findDestination(vehicle, markerId, fillType, noRobot)
    local markerX, markerZ = getMarkerPosition(markerId)
    if markerX == nil then
        return nil
    end
    local pointX, pointZ = ADAddOn.getDischargePoint(vehicle, markerId, fillType)
    pointX, pointZ = pointX or markerX, pointZ or markerZ
    local radius = getSearchRadius(vehicle)

    -- a robot barn: always the robot's own storage for this fill type, never the barn's trough
    local robotTrigger, robotBin = nil, nil
    if not noRobot then
        robotTrigger, robotBin = ADAddOn.findRobotTrigger(markerX, markerZ, radius, pointX, pointZ, fillType)
    end
    if robotTrigger ~= nil then
        ADAddOn.log(vehicle, "destination: the feeding robot's %s bin at the barn by the 2nd target (%s / %s l)",
            tostring(g_fillTypeManager:getFillTypeNameByIndex(fillType)),
            tostring(robotBin ~= nil and robotBin.fillLevel or "?"), tostring(robotBin ~= nil and robotBin.capacity or "?"))
        return robotTrigger, "robot"
    end

    local spec = getSpec(vehicle)
    local learned = spec ~= nil and spec.learned ~= nil and spec.learned[learnedKey(markerId, fillType)] or nil
    if isUnloadTrigger(learned) and learned:getFillUnitAllowsFillType(1, fillType) then
        return learned, "learned"
    end

    local best, bestDistance = nil, math.huge
    local checked = {}
    for node, object in pairs(g_currentMission.nodeToObject) do
        if not checked[object] and object.exactFillRootNode == node and isUnloadTrigger(object) then
            checked[object] = true
            if object:getFillUnitAllowsFillType(1, fillType) then
                local x, _, z = getWorldTranslation(node)
                if MathUtil.vector2Length(x - markerX, z - markerZ) <= radius then
                    local distance = MathUtil.vector2Length(x - pointX, z - pointZ)
                    if distance < bestDistance then
                        best, bestDistance = object, distance
                    end
                end
            end
        end
    end
    return best, "nearest"
end

-- same storage: the same unload trigger, or two triggers of one storage (the robot's raised and ground silage points)
local function isSameDestination(a, b)
    if a == nil or b == nil then
        return false
    end
    local binA, binB = ADAddOn.robotBinOf[a], ADAddOn.robotBinOf[b]
    if binA ~= nil or binB ~= nil then
        return binA == binB
    end
    return a == b or (a.target ~= nil and a.target == b.target)
end

-- what the tipping point of the trailer that carries this fill type is over right now (nil = nothing)
function ADAddOn.getDischargeObject(vehicle, fillType)
    for _, v in ipairs(vehicle:getChildVehicles()) do
        if v.getCurrentDischargeNode ~= nil and v.getFillUnitFillType ~= nil then
            local dischargeNode = v:getCurrentDischargeNode()
            if dischargeNode ~= nil and dischargeNode.fillUnitIndex ~= nil and v:getFillUnitFillType(dischargeNode.fillUnitIndex) == fillType then
                return dischargeNode.dischargeObject
            end
        end
    end
    return nil
end

-- robot runs: AutoDrive may only tip into the robot's storage. Anything else the trailer passes over on the way
-- (the trough, another barn's spot) is not offered to AutoDrive, it drives on.
function ADAddOn.lookForPossibleUnloadTrigger(trailerModule, superFunc, trailer)
    local result = superFunc(trailerModule, trailer)
    local spec = getSpec(trailerModule.vehicle)
    local deliver = spec ~= nil and spec.isOn and spec.deliver or nil
    if result ~= nil and result.bunkerSiloArea == nil and deliver ~= nil and deliver.strict and trailer.getCurrentDischargeNode ~= nil then
        local dischargeNode = trailer:getCurrentDischargeNode()
        local object = dischargeNode ~= nil and dischargeNode.dischargeObject or nil
        if dischargeNode ~= nil and dischargeNode.fillUnitIndex ~= nil and trailer:getFillUnitFillType(dischargeNode.fillUnitIndex) == deliver.fillType
            and not isSameDestination(object, deliver.destination) then
            if spec.lastBlocked ~= object then
                spec.lastBlocked = object
                ADAddOn.log(trailerModule.vehicle, "not tipping into '%s': it is not the robot's storage", ADAddOn.nameOf(object))
            end
            trailerModule.siloTrigger = nil
            return nil
        end
    end
    return result
end

-- AutoDrive starts tipping: remember which unload trigger it really is, for the next trips to this marker
function ADAddOn.onStartUnloading(trailerModule, trailer, trigger)
    local vehicle = trailerModule.vehicle
    local spec = getSpec(vehicle)
    if g_server == nil or spec == nil or not spec.isOn or trailer == nil or trailer.getCurrentDischargeNode == nil
        or vehicle.ad == nil or vehicle.ad.stateModule:getSecondMarker() == nil then
        return
    end
    local dischargeNode = trailer:getCurrentDischargeNode()
    local object = dischargeNode ~= nil and dischargeNode.dischargeObject or nil
    if not isUnloadTrigger(object) or dischargeNode.fillUnitIndex == nil then
        return
    end
    local fillType = trailer:getFillUnitFillType(dischargeNode.fillUnitIndex)
    if spec.deliver ~= nil and spec.deliver.strict then
        ADAddOn.log(vehicle, "tipping %s into the robot's bin", tostring(g_fillTypeManager:getFillTypeNameByIndex(spec.deliver.fillType)))
        return
    end
    local key = learnedKey(vehicle.ad.stateModule:getSecondMarker().id, fillType)
    spec.learned = spec.learned or {}
    if spec.learned[key] ~= object then
        spec.learned[key] = object
        local planned = spec.deliver ~= nil and spec.deliver.destination or nil
        ADAddOn.log(vehicle, "tipping into '%s'%s", ADAddOn.nameOf(object),
            (planned ~= nil and planned ~= object) and (" (planned with '" .. ADAddOn.nameOf(planned) .. "', using this one from now on)") or "")
        if spec.deliver ~= nil then
            spec.deliver.destination = object
        end
    end
end

------------------------------------------------------------------------------------------------------------------------
-- Fill type helpers
------------------------------------------------------------------------------------------------------------------------

local function getFillTypeName(fillType)
    return g_fillTypeManager:getFillTypeNameByIndex(fillType) or ""
end

local function getFillTypeTitle(fillType)
    local desc = g_fillTypeManager:getFillTypeByIndex(fillType)
    return desc ~= nil and desc.title or getFillTypeName(fillType)
end

function ADAddOn.isMilk(fillType)
    return string.find(getFillTypeName(fillType), "MILK", 1, true) ~= nil
end

function ADAddOn.isMineralFeed(fillType)
    return getFillTypeName(fillType) == "MINERAL_FEED"
end

-- the bale fill types themselves (ROUNDBALE, SQUAREBALE_WHEAT...). NOT the game's isBaleType flag: that is set on
-- everything that can be baled, SILAGE included (in game 2026-11-01 every silage trip was skipped as "bales")
function ADAddOn.isBale(fillType)
    local name = getFillTypeName(fillType)
    return string.find(name, "ROUNDBALE", 1, true) == 1 or string.find(name, "SQUAREBALE", 1, true) == 1
end

function ADAddOn.getMilkFillTypes()
    if ADAddOn.milkFillTypes == nil then
        ADAddOn.milkFillTypes = {}
        for index, desc in pairs(g_fillTypeManager:getFillTypes()) do
            if desc.name ~= nil and string.find(desc.name, "MILK", 1, true) ~= nil then
                table.insert(ADAddOn.milkFillTypes, index)
            end
        end
        table.sort(ADAddOn.milkFillTypes)
    end
    return ADAddOn.milkFillTypes
end

-- the smallest load worth a trip. Target size known (Top It Off / Milk): 5 % of what the target holds, never more
-- than a full vehicle. Otherwise (Fill Robot, a selling point without a size): 1.5 % of what the vehicle holds
function ADAddOn.getMinTrip(capacity, targetCapacity)
    if targetCapacity ~= nil and targetCapacity > 0 and targetCapacity < math.huge then
        return math.max(ADAddOn.MIN_AMOUNT, math.min(capacity, targetCapacity * ADAddOn.MIN_TARGET_SHARE))
    end
    return math.max(ADAddOn.MIN_AMOUNT, capacity * ADAddOn.MIN_TRIP_SHARE)
end

-- liters of a fill type the destination's storages hold in all (nil = unknown or unlimited, e.g. a selling point)
function ADAddOn.getTargetCapacity(unloadTrigger, fillType)
    local target = unloadTrigger ~= nil and unloadTrigger.target or nil
    if target == nil then
        return nil
    end
    local bin = ADAddOn.robotBinOf[unloadTrigger]
    if bin ~= nil and type(bin.capacity) == "number" then
        return bin.capacity
    end
    local total, found = 0, false
    for _, key in ipairs({"targetStorages", "storages"}) do
        local list = target[key]
        if type(list) == "table" then
            for _, storage in pairs(list) do
                if type(storage) == "table" and storage.getCapacity ~= nil and (storage.fillTypes == nil or storage.fillTypes[fillType]) then
                    local capacity = storage:getCapacity(fillType)
                    if type(capacity) == "number" then
                        total = total + capacity
                        found = true
                    end
                end
            end
            if found then
                return total
            end
        end
    end
    return nil
end

local function formatLiters(liters)
    local text = tostring(math.floor(liters + 0.5))
    local formatted = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if formatted:sub(1, 1) == "," then
        formatted = formatted:sub(2)
    end
    return formatted .. " l"
end

------------------------------------------------------------------------------------------------------------------------
-- Messages (AutoDrive's own message system)
------------------------------------------------------------------------------------------------------------------------

-- every name goes in as an argument: the text is run through string.format on each player's PC, a "%" in a
-- vehicle or marker name inside the text itself would break it
function ADAddOn.sendMessage(vehicle, isWarning, text, ...)
    -- every message also in log.txt
    ADAddOn.log(vehicle, "message: " .. text, ...)
    local AD = ADAddOn.AD
    local messageType = isWarning and AD.ADMessagesManager.messageTypes.WARN or AD.ADMessagesManager.messageTypes.INFO
    AD.AutoDriveMessageEvent.sendMessageOrNotification(vehicle, messageType, "ADAddOn - %s: " .. text, ADAddOn.MESSAGE_TIME, vehicle.ad.stateModule:getName(), ...)
end

-- log.txt: what ADAddOn found and decided, one line per step, so a run can be followed afterwards
function ADAddOn.log(vehicle, text, ...)
    local name = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule:getName() or "?"
    Logging.info("[ADAddOn] %s: " .. text, name, ...)
end

-- a readable name for a load trigger (its storage) or an unload trigger (its target)
function ADAddOn.nameOf(object)
    if object == nil then
        return "none"
    end
    -- (not ipairs over {source, target, object}: it stops at the first nil)
    for _, key in ipairs({"source", "target", "self"}) do
        local o = key == "self" and object or object[key]
        if type(o) == "table" then
            if type(o.getName) == "function" then
                local name = o:getName()
                if name ~= nil and name ~= "" then
                    return tostring(name)
                end
            end
            local placeable = o.owningPlaceable
            if type(placeable) == "table" and type(placeable.getName) == "function" then
                local name = placeable:getName()
                if name ~= nil then
                    return tostring(name)
                end
            end
        end
    end
    return tostring(object)
end

-- a warning that would repeat every trip is only sent once per run
local function warnOnce(vehicle, key, text, ...)
    local spec = getSpec(vehicle)
    spec.warned = spec.warned or {}
    -- every reason goes to log.txt too, also when the on-screen message was already shown this run
    ADAddOn.log(vehicle, "warning (%s): " .. text, key, ...)
    if not spec.warned[key] then
        spec.warned[key] = true
        ADAddOn.sendMessage(vehicle, true, text, ...)
    end
end

------------------------------------------------------------------------------------------------------------------------
-- The run
------------------------------------------------------------------------------------------------------------------------

function ADAddOn.onSwitched(vehicle, isOn)
    local spec = getSpec(vehicle)
    spec.job = nil
    spec.deliver = nil
    spec.warned = nil
    spec.robotRun = nil
    if not ADAddOn.isReady or vehicle.ad == nil or vehicle.ad.stateModule == nil then
        return
    end
    if isOn and spec.mode == ADAddOnSpec.MODE_BALES then
        ADAddOn.ensureBaleHelper(vehicle)
    else
        ADAddOn.restoreHelper(vehicle)
    end
    -- Repair/Refill: switched off (or another mode picked) during a run ends it where it is
    if ADAddOn.rrRuns[vehicle] ~= nil and not (isOn and spec.mode == ADAddOnSpec.MODE_REPAIR_REFILL) then
        local wasActive = vehicle.ad.stateModule:isActive()
        ADAddOn.endRepairRefill(vehicle, false)
        if wasActive then
            vehicle.ad.isStoppingWithError = true
            vehicle:stopAutoDrive()
        end
    end
    if g_server ~= nil and isOn and spec.mode == ADAddOnSpec.MODE_REPAIR_REFILL and ADAddOn.rrRuns[vehicle] == nil then
        if ADAddOn.repairRefillReady then
            ADAddOn.startRepairRefill(vehicle)
        else
            ADAddOn.sendMessage(vehicle, true, "Refuel/Repair is not available with this AutoDrive version.")
            vehicle:setADAddOn(false)
        end
    end
end

-- give the Courseplay helper settings back the way they were before Bale Collection
function ADAddOn.restoreHelper(vehicle)
    local spec = getSpec(vehicle)
    if spec.previousHelper ~= nil then
        local stateModule = vehicle.ad.stateModule
        stateModule:setUsedHelper(spec.previousHelper.usedHelper)
        stateModule:setStartHelper(spec.previousHelper.startHelper)
        spec.previousHelper = nil
    end
end

-- another mode picked in the menu: a new run, and the Courseplay helper only for Bale Collection
function ADAddOn.onModeChanged(vehicle, mode)
    ADAddOn.onSwitched(vehicle, getSpec(vehicle).isOn)
end

function ADAddOn.canCollectBales(vehicle)
    return vehicle.getCanStartCpBaleFinder ~= nil and vehicle.cpStartStopDriver ~= nil and vehicle:getCanStartCpBaleFinder()
end

-- bales: AutoDrive's Courseplay helper does the hand-over both ways (Courseplay full -> AutoDrive delivers -> back to
-- the 1st target -> Courseplay continues collecting)
function ADAddOn.ensureBaleHelper(vehicle)
    if not ADAddOn.canCollectBales(vehicle) then
        return
    end
    local spec = getSpec(vehicle)
    local stateModule = vehicle.ad.stateModule
    local ADStateModule = ADAddOn.AD.ADStateModule
    if stateModule:getUsedHelper() ~= ADStateModule.HELPER_CP or not stateModule:getStartHelper() then
        if spec.previousHelper == nil then
            spec.previousHelper = {usedHelper = stateModule:getUsedHelper(), startHelper = stateModule:getStartHelper()}
        end
        stateModule:setUsedHelper(ADStateModule.HELPER_CP)
        stateModule:setStartHelper(true)
    end
end

-- Bale Collection, just before AutoDrive hands over to Courseplay: give Courseplay's bale job a point that is surely on
-- the field. Courseplay's bale job keeps the field position of its previous start and does not detect the field again
-- while that position is unchanged (CpAIJobBaleFinder:applyCurrentState / CpAIJob:detectFieldBoundary), so one start
-- next to the field (a pin just off it) leaves it waiting for a field boundary forever. The field's own centre point
-- (the farmland's field, posX / posZ, as Courseplay's CpFieldUtil uses it) is always on the field.
function ADAddOn.beforePassToCp(vehicle)
    local spec = getSpec(vehicle)
    local cpSpec = vehicle ~= nil and vehicle.spec_cpAIBaleFinder or nil
    if not ADAddOn.isReady or spec == nil or not spec.isOn or spec.mode ~= ADAddOnSpec.MODE_BALES or cpSpec == nil or cpSpec.cpJob == nil
        or g_farmlandManager == nil then
        return
    end
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    local farmland = g_farmlandManager:getFarmlandAtWorldPosition(x, z)
    local field = farmland ~= nil and farmland.getField ~= nil and farmland:getField() or nil
    if field == nil or field.posX == nil or field.posZ == nil then
        ADAddOn.log(vehicle, "bale collection: no field at %.1f %.1f, Courseplay keeps its own field position", x, z)
        return
    end
    for _, job in ipairs({cpSpec.cpJob, cpSpec.cpJobStartAtLastWp}) do
        local parameters = job ~= nil and job.getCpJobParameters ~= nil and job:getCpJobParameters() or nil
        if parameters ~= nil and parameters.fieldPosition ~= nil then
            parameters.fieldPosition:setPosition(field.posX, field.posZ)
        end
    end
    ADAddOn.log(vehicle, "bale collection: Courseplay field position set to field %s (%.1f %.1f)",
        tostring(field.getId ~= nil and field:getId() or "?"), field.posX, field.posZ)
end

-- Bale Collection: AutoDrive hands over to Courseplay. Courseplay's startCpAtLastWp tries field work first and only
-- collects bales when that's not possible (CpAIBaleFinder:startCpAtLastWp / CpAIFieldWorker:startCpAtLastWp), so a
-- course loaded on the vehicle made it start field work. Start the bale job the same way Courseplay does, without
-- the field work try.
function ADAddOn.startCp(autoDrive, superFunc, vehicle)
    local cpSpec = vehicle ~= nil and vehicle.spec_cpAIBaleFinder or nil
    if vehicle ~= nil and ADAddOn.isReady and ADAddOn.isOn(vehicle) and getMode(vehicle) == ADAddOnSpec.MODE_BALES
        and cpSpec ~= nil and cpSpec.cpJobStartAtLastWp ~= nil and ADAddOn.canCollectBales(vehicle) then
        local job = cpSpec.cpJobStartAtLastWp
        job:applyCurrentState(vehicle, g_currentMission, g_currentMission.playerSystem:getLocalPlayer().farmId, true)
        job:setValues()
        if job:validate(false) then
            ADAddOn.log(vehicle, "bale collection: Courseplay started collecting bales")
            g_client:getServerConnection():sendEvent(AIJobStartRequestEvent.new(job, vehicle:getOwnerFarmId()))
            return
        end
        ADAddOn.log(vehicle, "bale collection: Courseplay's bale job did not validate, leaving the start to Courseplay")
    end
    return superFunc(autoDrive, vehicle)
end

-- Courseplay's bale job ends: the same choice as AIDriveStrategyFindBales:finishJob. Not full, and either nothing
-- loaded (and no bales of a wrong wrap type left) or the loader is changing bale size = the field is clear.
-- (Full, or bales on board with none left on the field, stops as "full" and AutoDrive delivers them.)
function ADAddOn.onBaleJobFinish(strategy)
    local vehicle = strategy.vehicle
    if g_server == nil or vehicle == nil or not ADAddOn.isOn(vehicle) or vehicle.ad == nil or getMode(vehicle) ~= ADAddOnSpec.MODE_BALES
        or strategy:areBaleLoadersFull() then
        return
    end
    local fieldClear
    if strategy:hasBalesLoaded() then
        fieldClear = strategy.baleLoaderController ~= nil and strategy.baleLoaderController:isChangingBaleSize()
    else
        fieldClear = not (strategy.baleLoader and strategy.wrongWrapTypeFound)
    end
    if fieldClear then
        ADAddOn.sendMessage(vehicle, false, "no bales left on the field. Done.")
        vehicle:setADAddOn(false)
        if ADAddOn.getParkMarker(vehicle) ~= nil then
            -- Courseplay is still ending its job here: park once it has let go (ADAddOn:update)
            ADAddOn.parkWhenFree[vehicle] = g_currentMission.time
        end
    end
end

-- Bale Collection done with a parking position set: vehicles waiting for Courseplay to let go before they park
ADAddOn.parkWhenFree = setmetatable({}, {__mode = "k"})
ADAddOn.PARK_WAIT_MAX = 60000

function ADAddOn:update(dt)
    if not ADAddOn.isReady or g_server == nil then
        return
    end
    if next(ADAddOn.rrRuns) ~= nil or next(ADAddOn.rrPending) ~= nil then
        ADAddOn.updateRepairRefill()
    end
    if next(ADAddOn.parkWhenFree) == nil then
        return
    end
    for vehicle, since in pairs(ADAddOn.parkWhenFree) do
        local cpActive = vehicle.getIsCpActive ~= nil and vehicle:getIsCpActive()
        local aiActive = vehicle.getIsAIActive ~= nil and vehicle:getIsAIActive()
        if vehicle.isDeleted or vehicle.ad == nil or ADAddOn.isOn(vehicle) or g_currentMission.time - since > ADAddOn.PARK_WAIT_MAX then
            ADAddOn.parkWhenFree[vehicle] = nil
        elseif not cpActive and not aiActive then
            ADAddOn.parkWhenFree[vehicle] = nil
            local marker = ADAddOn.getParkMarker(vehicle)
            if marker ~= nil and ADAddOn.AD.ADInputManager ~= nil then
                -- the same as pressing AutoDrive's own "park" button
                ADAddOn.log(vehicle, "bales done, driving to parking position '%s'", tostring(marker.name))
                ADAddOn.AD.ADInputManager:input_parkVehicle(vehicle, vehicle:getOwnerFarmId())
            end
        end
    end
end

function ADAddOn.onPickupAndDeliverStart(mode, user)
    local spec = getSpec(mode.vehicle)
    if spec ~= nil then
        spec.job = nil
        spec.deliver = nil
        spec.warned = nil
        spec.robotRun = nil
        spec.firstTargetFilledIn = false
        -- Fill Robot: only the barn is picked (2nd target). AutoDrive's start refuses an empty 1st target, so give it
        -- one; every pickup trip sets the real one.
        local stateModule = mode.vehicle.ad ~= nil and mode.vehicle.ad.stateModule or nil
        if ADAddOn.isReady and g_server ~= nil and spec.isOn and ADAddOnSpec.isFillRobotMode(spec.mode) and stateModule ~= nil
            and stateModule:getFirstMarker() == nil and stateModule:getSecondMarker() ~= nil then
            stateModule:setFirstMarkerByWayPointId(stateModule:getSecondMarker().id)
            spec.firstTargetFilledIn = true
            ADAddOn.log(mode.vehicle, "fill feeding robot: no 1st target set, ADAddOn fills it in")
        end
    end
end

-- the vehicle's AutoDrive parking position (set with AutoDrive's "set parking position" button), nil = none set
function ADAddOn.getParkMarker(vehicle)
    local stateModule = vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if stateModule == nil or stateModule.getParkDestinationAtJobFinished == nil then
        return nil
    end
    local markerId = stateModule:getParkDestinationAtJobFinished()
    if markerId == nil or markerId < 1 then
        return nil
    end
    local marker = ADAddOn.AD.ADGraphManager:getMapMarkerById(markerId)
    if marker == nil or marker.id == nil then
        return nil
    end
    return marker
end

-- ends the run and the ADAddOn button switches itself off. jobDone = the job is finished: with a parking position
-- set, AutoDrive first drives there (AutoDrive's own "park" state, which then stops AutoDrive), otherwise it stops
-- where it is (same task AutoDrive uses when its loops are done). A run stopped with a problem always stops where it is.
local function finishRun(mode, jobDone)
    local AD = ADAddOn.AD
    local vehicle = mode.vehicle
    local spec = getSpec(vehicle)
    spec.job = nil
    spec.deliver = nil
    if spec.isOn then
        vehicle:setADAddOn(false)
    end
    vehicle.ad.stateModule:setLoopsDone(0)
    local marker = nil
    if jobDone and AD.DriveToDestinationTask ~= nil and AD.PickupAndDeliverMode.STATE_PARK ~= nil then
        marker = ADAddOn.getParkMarker(vehicle)
    end
    if marker ~= nil then
        ADAddOn.log(vehicle, "job done, driving to parking position '%s'", tostring(marker.name))
        vehicle.ad.onRouteToPark = true
        mode.state = AD.PickupAndDeliverMode.STATE_PARK
        return AD.DriveToDestinationTask:new(vehicle, marker.id)
    end
    mode.state = AD.PickupAndDeliverMode.STATE_FINISHED
    return AD.StopAndDisableADTask:new(vehicle, AD.ADTaskModule.DONT_PROPAGATE)
end

-- when the source or destination isn't found: write what IS around the two targets to log.txt
function ADAddOn.logSurroundings(vehicle, fillType, farmId)
    local stateModule = vehicle.ad.stateModule
    local graph = ADAddOn.AD.ADGraphManager
    local first = graph:getWayPointById(stateModule:getFirstMarker().id)
    local second = graph:getWayPointById(stateModule:getSecondMarker().id)
    ADAddOn.log(vehicle, "search radius %.0f m (train length + %d)", getSearchRadius(vehicle), ADAddOn.SEARCH_EXTRA)
    if first ~= nil then
        for _, trigger in pairs(ADAddOn.AD.ADTriggerManager.getLoadTriggers()) do
            if trigger.triggerNode ~= nil and entityExists(trigger.triggerNode) then
                local x, _, z = getWorldTranslation(trigger.triggerNode)
                local distance = MathUtil.vector2Length(x - first.x, z - first.z)
                if distance < 150 then
                    local levels = trigger.source ~= nil and trigger.source.getAllFillLevels ~= nil and trigger.source:getAllFillLevels(farmId) or nil
                    ADAddOn.log(vehicle, "  near 1st target: loading point '%s' at %.0f m, isLoadTrigger %s, fill type allowed %s, storage has it %s (%s l)",
                        ADAddOn.nameOf(trigger), distance, tostring(trigger.loadTriggerCallback ~= nil),
                        tostring(trigger.fillTypes == nil or trigger.fillTypes[fillType] == true),
                        tostring(levels ~= nil and levels[fillType] ~= nil), tostring(levels ~= nil and levels[fillType] or "-"))
                end
            end
        end
    end
    if second ~= nil and g_currentMission.placeableSystem ~= nil then
        for _, placeable in pairs(g_currentMission.placeableSystem.placeables) do
            local spec = placeable.spec_husbandryFeedingRobot
            if spec ~= nil and placeable.rootNode ~= nil then
                local x, _, z = getWorldTranslation(placeable.rootNode)
                local distance = MathUtil.vector2Length(x - second.x, z - second.z)
                if distance < 300 then
                    local robot = spec.feedingRobot
                    local bins = type(robot) == "table" and type(robot.unloadingSpots) == "table" and robot.unloadingSpots or {}
                    ADAddOn.log(vehicle, "  near 2nd target: robot barn '%s' at %.0f m, robot %s, %d bins", ADAddOn.nameOf(placeable), distance, tostring(type(robot)), #bins)
                    for binIndex, bin in ipairs(bins) do
                        local found = {}
                        collectUnloadTriggers(bin, 1, found, {count = 0})
                        local nearest = math.huge
                        for trigger in pairs(found) do
                            local tx, _, tz = getWorldTranslation(trigger.exactFillRootNode)
                            nearest = math.min(nearest, MathUtil.vector2Length(tx - second.x, tz - second.z))
                        end
                        local keys = {}
                        for key, value in pairs(bin) do
                            table.insert(keys, tostring(key) .. "=" .. type(value))
                        end
                        ADAddOn.log(vehicle, "    bin %d: takes %s %s, %s / %s l, %d tipping points, nearest %.0f m from the 2nd target, fields: %s",
                            binIndex, getFillTypeName(fillType), tostring(robotBinTakes(robot, binIndex, bin, fillType)),
                            tostring(bin.fillLevel), tostring(bin.capacity), (function() local c = 0 for _ in pairs(found) do c = c + 1 end return c end)(), nearest, table.concat(keys, ", "))
                    end
                end
            end
        end
        local checked = {}
        for node, object in pairs(g_currentMission.nodeToObject) do
            if not checked[object] and object.exactFillRootNode == node and isUnloadTrigger(object) then
                checked[object] = true
                local x, _, z = getWorldTranslation(node)
                local distance = MathUtil.vector2Length(x - second.x, z - second.z)
                if distance < 80 then
                    ADAddOn.log(vehicle, "  near 2nd target: unload point '%s' at %.0f m, takes %s %s, room %s l",
                        ADAddOn.nameOf(object), distance, getFillTypeName(fillType), tostring(object:getFillUnitAllowsFillType(1, fillType)),
                        tostring(ADAddOn.getFreeCapacity(object, fillType, farmId)))
                end
            end
        end
    end
end

-- the feeding robot bin for this fill type, straight from the barn (like FS25_FarmInventory reads it):
-- the farm's barns with a feeding robot -> robot.unloadingSpots -> the bin that takes the fill type.
-- One such barn: that one. Several: the one closest to the 2nd target (only to tell barns apart).
function ADAddOn.findRobotBin(vehicle, fillType, farmId)
    local placeables = g_currentMission.placeableSystem ~= nil and g_currentMission.placeableSystem.placeables or nil
    if placeables == nil then
        return nil
    end
    local second = ADAddOn.AD.ADGraphManager:getWayPointById(vehicle.ad.stateModule:getSecondMarker().id)
    local best, bestPlaceable, bestDistance = nil, nil, math.huge
    for _, placeable in pairs(placeables) do
        local spec = placeable.spec_husbandryFeedingRobot
        local robot = spec ~= nil and spec.feedingRobot or nil
        local owner = placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or farmId
        if type(robot) == "table" and type(robot.unloadingSpots) == "table" and owner == farmId then
            for binIndex, bin in ipairs(robot.unloadingSpots) do
                if type(bin) == "table" and robotBinTakes(robot, binIndex, bin, fillType)
                    and type(bin.capacity) == "number" and type(bin.fillLevel) == "number" then
                    local distance = 0
                    if second ~= nil and placeable.rootNode ~= nil then
                        local x, _, z = getWorldTranslation(placeable.rootNode)
                        distance = MathUtil.vector2Length(x - second.x, z - second.z)
                    end
                    if best == nil or distance < bestDistance then
                        best, bestPlaceable, bestDistance = bin, placeable, distance
                    end
                end
            end
        end
    end
    if best == nil then
        return nil
    end
    -- its tipping points, so the trailer only tips into this bin
    local found = {}
    collectUnloadTriggers(best, 1, found, {count = 0})
    local trigger = nil
    for t in pairs(found) do
        ADAddOn.robotBinOf[t] = best
        trigger = trigger or t
    end
    return best, trigger, bestPlaceable
end

-- top off: move exactly what the destination still takes
-- noRobot: Top It Off, the 2nd target is the tip whatever robot is near it
function ADAddOn.planTopOff(mode, fillType, farmId, noRobot)
    local vehicle = mode.vehicle
    local stateModule = vehicle.ad.stateModule
    local spec = getSpec(vehicle)
    local title = getFillTypeTitle(fillType)

    local need, destination, bin, foundBy = nil, nil, nil, nil
    local robotBin, robotTrigger, barn = nil, nil, nil
    if not noRobot then
        robotBin, robotTrigger, barn = ADAddOn.findRobotBin(vehicle, fillType, farmId)
    end
    if robotBin ~= nil then
        -- the robot's bin: its own capacity and fill level, whatever the pins are
        bin, destination, foundBy = robotBin, robotTrigger, "robot"
        need = math.max(0, robotBin.capacity - robotBin.fillLevel)
        ADAddOn.log(vehicle, "robot bin %s at '%s': %s / %s l, room %s l", getFillTypeName(fillType), ADAddOn.nameOf(barn),
            tostring(robotBin.fillLevel), tostring(robotBin.capacity), tostring(need))
    else
        destination, foundBy = ADAddOn.findDestination(vehicle, stateModule:getSecondMarker().id, fillType, noRobot)
        if destination == nil then
            ADAddOn.logSurroundings(vehicle, fillType, farmId)
            warnOnce(vehicle, "noDestination", "nothing that takes %s found at %s, driving as normal AutoDrive.", title, stateModule:getSecondMarkerName())
            return nil
        end
        need = ADAddOn.getFreeCapacity(destination, fillType, farmId)
    end

    -- the source only tells how much there is to take; without it the load is still capped at what's needed
    local source = ADAddOn.findSource(vehicle, stateModule:getFirstMarker().id, fillType, farmId)
    local loaded = ADAddOn.getLoaded(vehicle, fillType)
    -- a buying station (e.g. a multi-fruit silo you buy from) never runs out, same as Fill Robot treats it
    local sourcePlaceable = source ~= nil and source.source ~= nil and source.source.owningPlaceable or nil
    local fromBuyingStation = sourcePlaceable ~= nil and sourcePlaceable.spec_buyingStation ~= nil
    local available = math.huge
    if source ~= nil and not fromBuyingStation then
        available = ADAddOn.getSourceLevel(source, fillType, farmId) + loaded
    end
    local capacity = ADAddOn.getCapacity(vehicle, fillType)
    ADAddOn.log(vehicle, "top off %s: source '%s', destination '%s' takes %s, on board %s, source has %s, vehicle holds %s",
        getFillTypeName(fillType), ADAddOn.nameOf(source), ADAddOn.nameOf(destination), tostring(need), tostring(loaded),
        fromBuyingStation and "unlimited (buying station)" or (source ~= nil and tostring(available - loaded) or "unknown"), tostring(capacity))

    -- not worth a trip below the minimum load (Top It Off: 5 % of the target, else 1.5 % of the vehicle)
    local minTrip = ADAddOn.getMinTrip(capacity, noRobot and ADAddOn.getTargetCapacity(destination, fillType) or nil)
    if need < minTrip then
        ADAddOn.sendMessage(vehicle, false, "%s is full of %s. Done.", stateModule:getSecondMarkerName(), title)
        return finishRun(mode, true)
    end
    -- Top It Off takes the source down to MIN_SOURCE (or a full vehicle, if it holds less)
    local sourceMin = noRobot and math.max(ADAddOn.MIN_AMOUNT, math.min(capacity, ADAddOn.MIN_SOURCE)) or minTrip
    if available < sourceMin then
        if noRobot then
            -- Top It Off: the loading point is empty, nothing more to do
            ADAddOn.sendMessage(vehicle, true, "Out of %s at %s.", title, stateModule:getFirstMarkerName())
            return finishRun(mode)
        end
        if need == math.huge then
            -- a destination without a limit (e.g. a selling point): the source is simply empty
            ADAddOn.sendMessage(vehicle, false, "no %s left at %s. Done.", title, stateModule:getFirstMarkerName())
            return finishRun(mode, true)
        end
        ADAddOn.sendMessage(vehicle, true, "%s missing, cannot fill %s (%s short).", title, stateModule:getSecondMarkerName(), formatLiters(need))
        return finishRun(mode)
    end
    if capacity < ADAddOn.MIN_AMOUNT then
        ADAddOn.logSurroundings(vehicle, fillType, farmId)
        warnOnce(vehicle, "noCapacity", "this vehicle can't carry %s, driving as normal AutoDrive.", title)
        return nil
    end

    ADAddOn.useOnlyFillType(stateModule, fillType)
    spec.job = {fillType = fillType, source = source, loadTarget = math.min(need, available, capacity), fromBuyingStation = fromBuyingStation}
    spec.deliver = {fillType = fillType, destination = destination, bin = bin, strict = foundBy == "robot" and destination ~= nil, minTrip = minTrip,
        sourceMin = noRobot and sourceMin or nil}
    ADAddOn.log(vehicle, "this trip: load %s l %s", tostring(spec.job.loadTarget), getFillTypeName(fillType))
    return true
end

-- AutoDrive switches between all selected fill types while loading; a planned load is one type only
function ADAddOn.useOnlyFillType(stateModule, fillType)
    if stateModule:getFillType() ~= fillType then
        stateModule:setFillType(fillType)
    end
    local selected = stateModule:getSelectedFillTypes()
    if selected == nil or #selected ~= 1 or selected[1] ~= fillType then
        stateModule.selectedFillTypes = {fillType}
        stateModule:raiseDirtyFlag()
    end
end

-- milk: every milk type the barn has, one type per load, to the one destination
function ADAddOn.planMilk(mode, farmId)
    local vehicle = mode.vehicle
    local stateModule = vehicle.ad.stateModule
    local spec = getSpec(vehicle)
    local firstMarkerId = stateModule:getFirstMarker().id
    local secondMarkerId = stateModule:getSecondMarker().id

    -- a milk type already on board goes first, then the selected one, then the rest
    local onBoard, selected, rest = {}, {}, {}
    for _, fillType in ipairs(ADAddOn.getMilkFillTypes()) do
        if ADAddOn.getLoaded(vehicle, fillType) >= ADAddOn.MIN_AMOUNT then
            table.insert(onBoard, fillType)
        elseif fillType == stateModule:getFillType() then
            table.insert(selected, fillType)
        else
            table.insert(rest, fillType)
        end
    end
    local order = {}
    for _, list in ipairs({onBoard, selected, rest}) do
        for _, fillType in ipairs(list) do
            table.insert(order, fillType)
        end
    end

    local milkLeft = nil
    local foundAnySource = false
    for _, fillType in ipairs(order) do
        local capacity = ADAddOn.getCapacity(vehicle, fillType)
        local source = nil
        if capacity >= ADAddOn.MIN_AMOUNT then
            source = ADAddOn.findSource(vehicle, firstMarkerId, fillType, farmId)
        end
        if source ~= nil then
            foundAnySource = true
        end
        local loaded = ADAddOn.getLoaded(vehicle, fillType)
        local available = ADAddOn.getSourceLevel(source, fillType, farmId) + loaded
        local destination, foundBy, free, minTrip = nil, nil, 0, ADAddOn.getMinTrip(capacity)
        -- the barn is emptied down to MIN_SOURCE (or a full vehicle, if it holds less)
        local sourceMin = math.max(ADAddOn.MIN_AMOUNT, math.min(capacity, ADAddOn.MIN_SOURCE))
        if capacity >= ADAddOn.MIN_AMOUNT and available >= sourceMin then
            destination, foundBy = ADAddOn.findDestination(vehicle, secondMarkerId, fillType)
            free = ADAddOn.getFreeCapacity(destination, fillType, farmId)
            minTrip = ADAddOn.getMinTrip(capacity, ADAddOn.getTargetCapacity(destination, fillType))
        end
        if capacity >= ADAddOn.MIN_AMOUNT and available >= sourceMin then
            ADAddOn.log(vehicle, "milk %s: source '%s' has %s, destination '%s' takes %s, on board %s, vehicle holds %s",
                getFillTypeName(fillType), ADAddOn.nameOf(source), tostring(available - loaded), ADAddOn.nameOf(destination), tostring(free), tostring(loaded), tostring(capacity))
            if free >= minTrip then
                ADAddOn.useOnlyFillType(stateModule, fillType)
                spec.job = {fillType = fillType, source = source, loadTarget = math.min(available, free, capacity)}
                spec.deliver = {fillType = fillType, destination = destination, strict = foundBy == "robot", minTrip = minTrip, sourceMin = sourceMin}
                ADAddOn.log(vehicle, "this trip: load %s l %s", tostring(spec.job.loadTarget), getFillTypeName(fillType))
                return true
            end
            milkLeft = milkLeft or fillType
        end
    end

    if not foundAnySource then
        warnOnce(vehicle, "noSource", "no milk found at %s, driving as normal AutoDrive.", stateModule:getFirstMarkerName())
        return nil
    end
    if milkLeft ~= nil then
        ADAddOn.sendMessage(vehicle, true, "%s can't take any more %s, milk left at %s.", stateModule:getSecondMarkerName(), getFillTypeTitle(milkLeft), stateModule:getFirstMarkerName())
        return finishRun(mode)
    end
    ADAddOn.sendMessage(vehicle, false, "all milk moved to %s. Done.", stateModule:getSecondMarkerName())
    return finishRun(mode, true)
end

-- called before each pickup trip; returns a task to use instead (stop), true when a load is planned, nil = normal AutoDrive
------------------------------------------------------------------------------------------------------------------------
-- Fill feeding robot mode: the player picks the barn (its robot barn is the one nearest the 2nd target). ADAddOn picks
-- the bin, the feed and the storage and sets AutoDrive's 1st target (and the 2nd target to that barn's pin for the bin).
-- Emptiest bin first; per bin the feed type the farm has most of first; per type the silos first, then the
-- productions; last resort (Fill Robot $$$ only) the farm's buying station, as much as the farm can pay.
------------------------------------------------------------------------------------------------------------------------

-- how close (m) the route into a target must pass to a loading / tipping point for that target to serve it
ADAddOn.TARGET_PASS_RADIUS = 15
-- robot tipping points: only a pin right over it, else the player's own barn pin (a wider rule picked the trough's pin)
ADAddOn.BIN_PASS_RADIUS = 6
-- a buying station without a pin whose route passes that close: its nearest pin, if within this many m
ADAddOn.NEAREST_PIN_MAX = 50

-- the fill types a robot bin takes, mineral feed left out
local function getBinFillTypes(robot, binIndex, bin)
    local list, seen = {}, {}
    local function add(fillType)
        if type(fillType) == "number" and not seen[fillType] and not ADAddOn.isMineralFeed(fillType)
            and g_fillTypeManager:getFillTypeByIndex(fillType) ~= nil then
            seen[fillType] = true
            table.insert(list, fillType)
        end
    end
    if type(bin.fillTypes) == "table" then
        for key, value in pairs(bin.fillTypes) do
            if value == true then
                add(key)
            else
                add(value)
            end
        end
    end
    add(bin.fillTypeIndex)
    add(bin.fillType)
    if type(robot.fillTypeToUnloadingSpot) == "table" then
        for fillType, target in pairs(robot.fillTypeToUnloadingSpot) do
            if target == bin or target == binIndex then
                add(fillType)
            end
        end
    end
    table.sort(list)
    return list
end

local function binTitle(fillTypes)
    if #fillTypes == 0 then
        return "?"
    end
    local titles = {}
    for i = 1, math.min(2, #fillTypes) do
        table.insert(titles, getFillTypeTitle(fillTypes[i]))
    end
    return table.concat(titles, "/") .. (#fillTypes > 2 and "..." or "")
end

-- the farm's barns with a feeding robot: {placeable, robot, bins = {{bin, index, fillTypes, triggers, title}}}
function ADAddOn.getRobotBarns(farmId)
    local barns = {}
    local placeables = g_currentMission.placeableSystem ~= nil and g_currentMission.placeableSystem.placeables or {}
    for _, placeable in pairs(placeables) do
        local spec = placeable.spec_husbandryFeedingRobot
        local robot = spec ~= nil and spec.feedingRobot or nil
        local owner = placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or farmId
        if type(robot) == "table" and type(robot.unloadingSpots) == "table" and owner == farmId and placeable.rootNode ~= nil then
            local barn = {placeable = placeable, robot = robot, bins = {}}
            for binIndex, bin in ipairs(robot.unloadingSpots) do
                if type(bin) == "table" and type(bin.capacity) == "number" and type(bin.fillLevel) == "number" and bin.capacity > 0 then
                    local fillTypes = getBinFillTypes(robot, binIndex, bin)
                    if #fillTypes > 0 then
                        local found = {}
                        collectUnloadTriggers(bin, 1, found, {count = 0})
                        local triggers = {}
                        for trigger in pairs(found) do
                            ADAddOn.robotBinOf[trigger] = bin
                            table.insert(triggers, trigger)
                        end
                        table.insert(barn.bins, {bin = bin, index = binIndex, fillTypes = fillTypes, triggers = triggers, title = binTitle(fillTypes)})
                    end
                end
            end
            if #barn.bins > 0 then
                table.insert(barns, barn)
            end
        end
    end
    return barns
end

-- an AutoDrive target whose route runs over the position (a loading or tipping point), so the train passes over it on
-- the way in. Never creates one. The nearest such target wins (no train-length rule).
-- map marker indexes some vehicle uses as its AutoDrive parking spot: never a loading/unloading target
local function getParkingMarkers()
    local parking = {}
    for _, other in pairs(ADAddOn.AD.AutoDrive.getAllVehicles()) do
        local stateModule = other.ad ~= nil and other.ad.stateModule or nil
        if stateModule ~= nil and stateModule.getParkDestinationAtJobFinished ~= nil then
            local index = stateModule:getParkDestinationAtJobFinished()
            if index ~= nil and index >= 1 then
                parking[index] = true
            end
        end
    end
    return parking
end

function ADAddOn.findTargetAt(vehicle, x, z, radius)
    radius = radius or ADAddOn.TARGET_PASS_RADIUS
    local AD = ADAddOn.AD
    local trainLength = AD.AutoDrive.getTractorTrainLength(vehicle, true, false)
    local parking = getParkingMarkers()
    local best, bestScore = nil, math.huge
    for markerIndex, mapMarker in pairs(AD.ADGraphManager:getMapMarkers()) do
        local wayPoint = not parking[markerIndex] and AD.ADGraphManager:getWayPointById(mapMarker.id) or nil
        if wayPoint ~= nil then
            local distance = MathUtil.vector2Length(wayPoint.x - x, wayPoint.z - z)
            if distance <= trainLength + ADAddOn.SEARCH_EXTRA
                and AD.AutoDrive:checkIfPathTraversedOverPosition(wayPoint, {x = x, z = z}, radius, 20) then
                -- the nearest pin wins, no length rule; the check above follows the route's incoming links backwards
                -- from the pin, so only a pin AutoDrive drives to over the point (one-way lanes respected) gets here
                if distance < bestScore then
                    best, bestScore = mapMarker, distance
                end
            end
        end
    end
    return best
end

local function getTriggerPosition(trigger)
    local node = trigger.aiNode
    if node == nil or not entityExists(node) then
        node = trigger.triggerNode or trigger.exactFillRootNode
    end
    if node == nil or not entityExists(node) then
        return nil
    end
    local x, _, z = getWorldTranslation(node)
    return x, z
end

-- the pin nearest a point, within maxDistance m (nil = none)
function ADAddOn.findNearestTarget(x, z, maxDistance)
    local AD = ADAddOn.AD
    local parking = getParkingMarkers()
    local best, bestDistance = nil, maxDistance
    for markerIndex, mapMarker in pairs(AD.ADGraphManager:getMapMarkers()) do
        local wayPoint = not parking[markerIndex] and AD.ADGraphManager:getWayPointById(mapMarker.id) or nil
        if wayPoint ~= nil then
            local distance = MathUtil.vector2Length(wayPoint.x - x, wayPoint.z - z)
            if distance <= bestDistance then
                best, bestDistance = mapMarker, distance
            end
        end
    end
    return best
end

-- for the log: the pin nearest a point, and how far
local function describeNearestTarget(x, z)
    local AD = ADAddOn.AD
    local best, bestDistance = nil, math.huge
    for _, mapMarker in pairs(AD.ADGraphManager:getMapMarkers()) do
        local wayPoint = AD.ADGraphManager:getWayPointById(mapMarker.id)
        if wayPoint ~= nil then
            local distance = MathUtil.vector2Length(wayPoint.x - x, wayPoint.z - z)
            if distance < bestDistance then
                best, bestDistance = mapMarker, distance
            end
        end
    end
    if best == nil then
        return "no pins"
    end
    return string.format("nearest pin '%s' %.0f m away", tostring(best.name), bestDistance)
end

-- the robot bin's tipping point that has an AutoDrive target: trigger, target. None: the pin the player picked the barn
-- with (fallbackMarker), the way a robot run worked with targets set by hand
local function findBinTarget(vehicle, binInfo, fallbackMarker)
    for _, trigger in ipairs(binInfo.triggers) do
        local x, z = getTriggerPosition(trigger)
        if x ~= nil then
            local marker = ADAddOn.findTargetAt(vehicle, x, z, ADAddOn.BIN_PASS_RADIUS)
            if marker ~= nil then
                return trigger, marker
            end
        end
    end
    if fallbackMarker ~= nil and binInfo.triggers[1] ~= nil then
        local x, z = getTriggerPosition(binInfo.triggers[1])
        ADAddOn.log(vehicle, "robot's %s tipping point: no pin's route passes within %d m (%s), using the 2nd target '%s'",
            binInfo.title, ADAddOn.BIN_PASS_RADIUS, x ~= nil and describeNearestTarget(x, z) or "no position", tostring(fallbackMarker.name))
        return binInfo.triggers[1], fallbackMarker
    end
    return nil
end

-- what kind of storage a load trigger belongs to: "silo", "production", "buy" or nil (barn, other)
local function getSourceKind(trigger, farmId)
    local station = trigger.source
    local placeable = station ~= nil and station.owningPlaceable or nil
    if placeable == nil then
        return nil
    end
    local owner = placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or nil
    if placeable.spec_buyingStation ~= nil then
        return owner == farmId and "buy" or nil
    end
    if owner ~= farmId and not station.hasStoragePerFarm then
        return nil
    end
    if placeable.spec_productionPoint ~= nil then
        return "production"
    end
    if placeable.spec_silo ~= nil then
        return "silo"
    end
    return nil
end

-- every storage of the farm that has the fill type: {trigger, kind, level, placeable}, one per storage
function ADAddOn.getFeedSources(fillType, farmId)
    local sources, seen = {}, {}
    for _, trigger in pairs(ADAddOn.AD.ADTriggerManager.getLoadTriggers()) do
        if trigger.source ~= nil and trigger.source.getAllFillLevels ~= nil and trigger.loadTriggerCallback ~= nil
            and (trigger.fillTypes == nil or trigger.fillTypes[fillType]) and trigger.triggerNode ~= nil and entityExists(trigger.triggerNode) then
            local kind = getSourceKind(trigger, farmId)
            local placeable = trigger.source.owningPlaceable
            if kind ~= nil and not seen[placeable] then
                local level = kind == "buy" and math.huge or ADAddOn.getSourceLevel(trigger, fillType, farmId)
                if level > 0 then
                    seen[placeable] = true
                    table.insert(sources, {trigger = trigger, kind = kind, level = level, placeable = placeable})
                end
            end
        end
    end
    return sources
end

function ADAddOn.getMoney(farmId)
    local farm = g_farmManager ~= nil and g_farmManager:getFarmById(farmId) or nil
    return farm ~= nil and farm.money or nil
end

local function formatMoney(amount)
    return g_i18n:formatMoney(amount, 0, true)
end

-- price per liter the buying station will roughly ask (only to plan the load; the real cost stops the loading)
local function estimateBuyPrice(fillType)
    local desc = g_fillTypeManager:getFillTypeByIndex(fillType)
    local price = desc ~= nil and desc.pricePerLiter or nil
    if type(price) ~= "number" or price <= 0 then
        return nil
    end
    if EconomyManager ~= nil and EconomyManager.getPriceMultiplier ~= nil then
        price = price * (EconomyManager.getPriceMultiplier(fillType) or 1)
    end
    return price
end

-- the buying station's own price scale for a fill type (its XML fillType#priceScale, e.g. 0.90 = 10% off), 1 = none
local function getStationPriceScale(station, fillType)
    for _, key in ipairs({"fillTypePricesScale", "fillTypePriceScales", "priceScales"}) do
        local scales = station[key]
        if type(scales) == "table" and type(scales[fillType]) == "number" and scales[fillType] > 0 then
            return scales[fillType]
        end
    end
    return 1
end

-- true when the station has a price entry for this fill type (getEffectiveFillTypePrice indexes these
-- tables without a nil check, so it is only asked for fill types the station really sells)
local function stationHasPriceFor(station, fillType)
    if type(fillType) ~= "number" then
        return false
    end
    for _, key in ipairs({"fillTypePrices", "fillTypePricesScale"}) do
        local prices = station[key]
        if type(prices) == "table" and prices[fillType] ~= nil then
            return true
        end
    end
    return false
end

-- price per liter the buying station really charges, and where it came from (for the log); nil = unknown
local function getStationPrice(trigger, fillType)
    local station = trigger ~= nil and trigger.source or nil
    if type(station) == "table" and type(station.getEffectiveFillTypePrice) == "function" and stationHasPriceFor(station, fillType) then
        local price = station:getEffectiveFillTypePrice(fillType)
        if type(price) == "number" and price > 0 then
            return price, "station price"
        end
    end
    local price = estimateBuyPrice(fillType)
    if price == nil then
        return nil
    end
    local scale = station ~= nil and getStationPriceScale(station, fillType) or 1
    return price * scale, string.format("market price x station scale %.2f", scale)
end

local function setTargets(vehicle, firstMarker, secondMarker)
    local stateModule = vehicle.ad.stateModule
    if stateModule:getFirstMarker() == nil or stateModule:getFirstMarker().id ~= firstMarker.id then
        stateModule:setFirstMarkerByWayPointId(firstMarker.id)
    end
    if stateModule:getSecondMarker() == nil or stateModule:getSecondMarker().id ~= secondMarker.id then
        stateModule:setSecondMarkerByWayPointId(secondMarker.id)
    end
    -- remembered, so a restart can tell the player's own pick from a pin ADAddOn set
    getSpec(vehicle).adSetSecondId = secondMarker.id
end

-- plan the next trip for one bin; true = planned, false = this bin can't be filled any further (reason sent)
local function planBin(mode, run, barn, binInfo, need, farmId)
    local vehicle = mode.vehicle
    local spec = getSpec(vehicle)
    local barnName = ADAddOn.nameOf(barn.placeable)

    local binTrigger, binMarker = findBinTarget(vehicle, binInfo, run.pickedMarker)
    if binTrigger == nil then
        ADAddOn.sendMessage(vehicle, true, "the robot's %s bin at %s has no tipping point ADAddOn can find. Skipped.", binInfo.title, barnName)
        return false
    end

    -- the feed types of this bin, the one the farm has most of first (silos and productions together)
    local candidates = {}
    for _, fillType in ipairs(binInfo.fillTypes) do
        local capacity = ADAddOn.getCapacity(vehicle, fillType)
        if capacity >= ADAddOn.MIN_AMOUNT then
            local total, own, buy = 0, {}, {}
            for _, source in ipairs(ADAddOn.getFeedSources(fillType, farmId)) do
                if source.kind == "buy" then
                    table.insert(buy, source)
                else
                    total = total + source.level
                    table.insert(own, source)
                end
            end
            table.insert(candidates, {fillType = fillType, total = total, own = own, buy = buy, capacity = capacity})
        end
    end
    if #candidates == 0 then
        -- another feed still on board takes the room: try this bin again once the truck is empty
        for _, fillType in ipairs(ADAddOn.getAllLoadedTypes(vehicle)) do
            ADAddOn.log(vehicle, "robot's %s bin: %s on board first, this bin waits", binInfo.title, getFillTypeName(fillType))
            return false, "busy"
        end
        ADAddOn.sendMessage(vehicle, true, "this vehicle can't carry the feed of the robot's %s bin at %s. Skipped.", binInfo.title, barnName)
        return false
    end
    table.sort(candidates, function(a, b)
        if a.total ~= b.total then
            return a.total > b.total
        end
        return a.fillType < b.fillType
    end)

    local function plan(candidate, source, marker, amount, buying, price)
        ADAddOn.useOnlyFillType(vehicle.ad.stateModule, candidate.fillType)
        setTargets(vehicle, marker, binMarker)
        spec.job = {fillType = candidate.fillType, source = source.trigger, loadTarget = amount, markerId = marker.id,
            buying = buying, fromBuyingStation = buying, moneyBefore = buying and ADAddOn.getMoney(farmId) or nil,
            price = buying and price or nil,
            loadedBefore = ADAddOn.getLoaded(vehicle, candidate.fillType), barn = barn.placeable, barnName = barnName}
        spec.deliver = {fillType = candidate.fillType, destination = binTrigger, bin = binInfo.bin, strict = true, markerId = binMarker.id}
        run.barn = barn.placeable
        ADAddOn.log(vehicle, "robot at '%s', %s bin %s / %s l: this trip %s l %s from '%s' (%s)%s", barnName, binInfo.title,
            tostring(binInfo.bin.fillLevel), tostring(binInfo.bin.capacity), tostring(amount), getFillTypeName(candidate.fillType),
            ADAddOn.nameOf(source.trigger), source.kind, buying and string.format(", %s per 1000 l, spent on buying this run so far %d",
                price ~= nil and formatMoney(price * 1000) or "price unknown", run.spentTotal or 0) or "")
        return true
    end

    -- own storage: silos first, then productions, the fullest of each first
    for _, candidate in ipairs(candidates) do
        local minTrip = ADAddOn.getMinTrip(candidate.capacity)
        if candidate.total >= minTrip then
            table.sort(candidate.own, function(a, b)
                if a.kind ~= b.kind then
                    return a.kind == "silo"
                end
                return a.level > b.level
            end)
            for _, source in ipairs(candidate.own) do
                if source.level >= minTrip then
                    local x, z = getTriggerPosition(source.trigger)
                    local marker = x ~= nil and ADAddOn.findTargetAt(vehicle, x, z) or nil
                    if marker ~= nil then
                        local loaded = ADAddOn.getLoaded(vehicle, candidate.fillType)
                        return plan(candidate, source, marker, math.min(need, source.level + loaded, candidate.capacity), false)
                    end
                    ADAddOn.log(vehicle, "'%s' has %s l %s but no pin's route passes within %d m of its loading point (%s), skipped",
                        ADAddOn.nameOf(source.trigger), tostring(source.level), getFillTypeName(candidate.fillType), ADAddOn.TARGET_PASS_RADIUS,
                        x ~= nil and describeNearestTarget(x, z) or "no position")
                end
            end
        end
    end

    -- Fill Robot - In Stock Only: never buys. Nothing (more) in the silos / productions: say so, the run goes on to the
    -- next bin (this one is marked failed by the caller) and ends as usual when no bin is left
    if getMode(vehicle) == ADAddOnSpec.MODE_FILL_ROBOT_STOCK then
        local names = {}
        for _, candidate in ipairs(candidates) do
            table.insert(names, getFillTypeTitle(candidate.fillType))
        end
        ADAddOn.sendMessage(vehicle, true, "%s out of stock (robot's %s bin at %s, %s short). Next bin.",
            table.concat(names, " / "), binInfo.title, barnName, formatLiters(need))
        return false
    end

    -- last resort (Fill Robot $$$): buy, as much as the farm can pay
    local noMoney = false
    do
        -- the buying station closest to the barn
        local barnX, _, barnZ = getWorldTranslation(barn.placeable.rootNode)
        for _, candidate in ipairs(candidates) do
            -- always the station closest to the barn, never a farther one
            local bestSource, bestDistance, bestX, bestZ = nil, math.huge, nil, nil
            for _, source in ipairs(candidate.buy) do
                local x, z = getTriggerPosition(source.trigger)
                if x ~= nil then
                    local distance = MathUtil.vector2Length(x - barnX, z - barnZ)
                    if distance < bestDistance then
                        bestSource, bestDistance, bestX, bestZ = source, distance, x, z
                    end
                end
            end
            local bestMarker = nil
            if bestSource ~= nil then
                bestMarker = ADAddOn.findTargetAt(vehicle, bestX, bestZ)
                if bestMarker == nil then
                    -- no pin's route passes close enough: the pin nearest that station
                    bestMarker = ADAddOn.findNearestTarget(bestX, bestZ, ADAddOn.NEAREST_PIN_MAX)
                    ADAddOn.log(vehicle, "buying station %.0f m from the barn: no pin's route passes within %d m of its loading point, using the nearest pin '%s'",
                        bestDistance, ADAddOn.TARGET_PASS_RADIUS, bestMarker ~= nil and tostring(bestMarker.name) or "none")
                end
                if bestMarker == nil then
                    bestSource = nil
                end
            end
            if bestSource ~= nil then
                local price, priceSource = getStationPrice(bestSource.trigger, candidate.fillType)
                ADAddOn.log(vehicle, "buying price %s per 1000 l %s (%s)", price ~= nil and formatMoney(price * 1000) or "unknown",
                    getFillTypeName(candidate.fillType), tostring(priceSource))
                local amount = math.min(need, candidate.capacity)
                -- never more than the farm can pay
                local money = ADAddOn.getMoney(farmId)
                local affordable = (price ~= nil and money ~= nil) and math.max(0, money) / price or math.huge
                local minTrip = ADAddOn.getMinTrip(candidate.capacity)
                if affordable < amount then
                    amount = affordable
                    if amount < minTrip then
                        noMoney = true
                    end
                end
                if amount >= minTrip then
                    return plan(candidate, bestSource, bestMarker, amount, true, price)
                end
            end
        end
    end

    local reason = noMoney and " (not enough money on the farm to buy it)" or ""
    ADAddOn.sendMessage(vehicle, true, "%s missing, cannot fill the robot's bin at %s (%s short)%s.", binInfo.title, barnName, formatLiters(need), reason)
    return false
end

-- the robot barn nearest the vehicle's 2nd target: the barn the player picked
local function getPickedBarn(vehicle, barns)
    local marker = vehicle.ad.stateModule:getSecondMarker()
    local wayPoint = marker ~= nil and ADAddOn.AD.ADGraphManager:getWayPointById(marker.id) or nil
    if wayPoint == nil then
        return nil
    end
    local best, bestDistance = nil, math.huge
    for _, barn in ipairs(barns) do
        local x, _, z = getWorldTranslation(barn.placeable.rootNode)
        local distance = MathUtil.vector2Length(x - wayPoint.x, z - wayPoint.z)
        if distance < bestDistance then
            best, bestDistance = barn, distance
        end
    end
    return best
end

-- the farm's animal barn (any husbandry) nearest the vehicle's 2nd target, or nil
local function getNearestHusbandry(vehicle, farmId)
    local marker = vehicle.ad.stateModule:getSecondMarker()
    local wayPoint = marker ~= nil and ADAddOn.AD.ADGraphManager:getWayPointById(marker.id) or nil
    if wayPoint == nil then
        return nil
    end
    local best, bestDistance = nil, math.huge
    local placeables = g_currentMission.placeableSystem ~= nil and g_currentMission.placeableSystem.placeables or {}
    for _, placeable in pairs(placeables) do
        local owner = placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or nil
        if (placeable.spec_husbandry ~= nil or placeable.spec_husbandryAnimals ~= nil) and owner == farmId and placeable.rootNode ~= nil then
            local x, _, z = getWorldTranslation(placeable.rootNode)
            local distance = MathUtil.vector2Length(x - wayPoint.x, z - wayPoint.z)
            if distance < bestDistance then
                best, bestDistance = placeable, distance
            end
        end
    end
    return best
end

-- the next trip of a fill-feeding-robot run: true = planned, a task = run finished, nil = robot barn without a tipping
-- point (drive the targets set by hand), false + message = no robot barn at the 2nd target: stop, never drive there
function ADAddOn.planRobotRun(mode, farmId)
    local vehicle = mode.vehicle
    local spec = getSpec(vehicle)
    local barns = ADAddOn.getRobotBarns(farmId)
    local secondName = tostring(vehicle.ad.stateModule:getSecondMarkerName())
    if #barns == 0 then
        return false, string.format("this farm has no barn with a feeding robot. Stopped.")
    end
    if spec.robotRun == nil then
        -- the 2nd target is at an animal barn without a feeding robot (alpacas, ...): Fill Robot never goes there
        local husbandry = getNearestHusbandry(vehicle, farmId)
        if husbandry ~= nil and husbandry.spec_husbandryFeedingRobot == nil then
            ADAddOn.log(vehicle, "2nd target '%s' is at '%s', which has no feeding robot: not driving there", secondName, ADAddOn.nameOf(husbandry))
            return false, string.format("2nd target %s is at %s, which has no feeding robot. Pick a pin at a robot barn. Stopped.",
                secondName, ADAddOn.nameOf(husbandry))
        end
        -- the run fills the barn picked as 2nd target, only that one
        local picked = getPickedBarn(vehicle, barns)
        if picked == nil then
            return false, string.format("no barn with a feeding robot found for 2nd target %s. Stopped.", secondName)
        end
        -- its robot has no tipping point ADAddOn can find: drive to the targets set by hand (top off)
        local anyTrigger = false
        for _, binInfo in ipairs(picked.bins) do
            anyTrigger = anyTrigger or binInfo.triggers[1] ~= nil
        end
        if not anyTrigger then
            ADAddOn.log(vehicle, "fill feeding robot: no tipping point found on the robot at '%s', using the targets set by hand",
                ADAddOn.nameOf(picked.placeable))
            return nil
        end
        -- the pin the player picked the barn with; a pin ADAddOn set on an earlier run does not count as a pick
        local second = vehicle.ad.stateModule:getSecondMarker()
        if second ~= nil and second.id ~= spec.adSetSecondId then
            spec.playerPickedMarker = {id = second.id, name = second.name}
        end
        local pickedMarker = spec.playerPickedMarker
        spec.robotRun = {barn = picked.placeable, pickedMarker = pickedMarker,
            bought = 0, spentTotal = 0, failedBins = {}}
        ADAddOn.log(vehicle, "fill feeding robot: barn '%s' (nearest the 2nd target)", ADAddOn.nameOf(picked.placeable))
    end
    local run = spec.robotRun

    for _, barn in ipairs(barns) do
        if barn.placeable == run.barn then
            -- bins with room, the emptiest (lowest share) first
            local open = {}
            for _, binInfo in ipairs(barn.bins) do
                local need = math.max(0, binInfo.bin.capacity - binInfo.bin.fillLevel)
                local minTrip = ADAddOn.getMinTrip(ADAddOn.getCapacity(vehicle, binInfo.fillTypes[1]))
                if not run.failedBins[binInfo.bin] and need >= minTrip then
                    table.insert(open, {info = binInfo, need = need, share = binInfo.bin.fillLevel / binInfo.bin.capacity})
                end
            end
            -- feed already on board goes to its own bin first, then the emptiest (lowest share) first
            local onBoard = {}
            for _, fillType in ipairs(ADAddOn.getAllLoadedTypes(vehicle)) do
                onBoard[fillType] = true
            end
            local function carries(entry)
                for _, fillType in ipairs(entry.info.fillTypes) do
                    if onBoard[fillType] then
                        return true
                    end
                end
                return false
            end
            -- feed on board first, then the bin this run is already filling (finish it), then the emptiest
            table.sort(open, function(a, b)
                local ca, cb = carries(a), carries(b)
                if ca ~= cb then
                    return ca
                end
                local fa, fb = a.info.bin == run.currentBin, b.info.bin == run.currentBin
                if fa ~= fb then
                    return fa
                end
                return a.share < b.share
            end)
            for _, entry in ipairs(open) do
                local planned, reason = planBin(mode, run, barn, entry.info, entry.need, farmId)
                if planned then
                    run.currentBin = entry.info.bin
                    return true
                end
                if reason ~= "busy" then
                    run.failedBins[entry.info.bin] = true
                end
            end
        end
    end

    ADAddOn.sendMessage(vehicle, false, "feeding robot at %s done%s.", ADAddOn.nameOf(run.barn),
        run.bought > 0 and string.format(", %s bought for %s", formatLiters(run.bought), formatMoney(run.spentTotal)) or "")
    spec.robotRun = nil
    return finishRun(mode, true)
end

-- the truck starts with feed on board: deliver it to the emptiest robot bin that takes it
function ADAddOn.planRobotDelivery(mode, farmId)
    local vehicle = mode.vehicle
    local spec = getSpec(vehicle)
    local best, bestBarn, bestShare = nil, nil, math.huge
    local barns = ADAddOn.getRobotBarns(farmId)
    local picked = spec.robotRun ~= nil and spec.robotRun.barn or nil
    if picked == nil then
        local barn = getPickedBarn(vehicle, barns)
        picked = barn ~= nil and barn.placeable or nil
    end
    for _, barn in ipairs(barns) do
        for _, binInfo in ipairs(barn.placeable == picked and barn.bins or {}) do
            for _, fillType in ipairs(binInfo.fillTypes) do
                if ADAddOn.getLoaded(vehicle, fillType) >= ADAddOn.MIN_AMOUNT and binInfo.bin.capacity - binInfo.bin.fillLevel >= ADAddOn.MIN_AMOUNT then
                    local share = binInfo.bin.fillLevel / binInfo.bin.capacity
                    if share < bestShare then
                        best, bestBarn, bestShare = {info = binInfo, fillType = fillType}, barn, share
                    end
                end
            end
        end
    end
    if best == nil then
        return
    end
    -- the 2nd target the player set now; a pin remembered from an earlier run must not win over it (in game
    -- 2026-11-06: an old Hay Dryer INPUT pick sent a silage delivery there)
    local second = vehicle.ad.stateModule:getSecondMarker()
    if second ~= nil and second.id ~= spec.adSetSecondId then
        spec.playerPickedMarker = {id = second.id, name = second.name}
    end
    local fallback = nil
    if spec.robotRun ~= nil and spec.robotRun.pickedMarker ~= nil then
        fallback = spec.robotRun.pickedMarker
    elseif spec.playerPickedMarker ~= nil then
        fallback = spec.playerPickedMarker
    elseif vehicle.ad.stateModule:getSecondMarker() ~= nil then
        fallback = {id = vehicle.ad.stateModule:getSecondMarker().id, name = vehicle.ad.stateModule:getSecondMarker().name}
    end
    local trigger, marker = findBinTarget(vehicle, best.info, fallback)
    if trigger == nil then
        return
    end
    if vehicle.ad.stateModule:getSecondMarker() == nil or vehicle.ad.stateModule:getSecondMarker().id ~= marker.id then
        vehicle.ad.stateModule:setSecondMarkerByWayPointId(marker.id)
    end
    spec.adSetSecondId = marker.id
    spec.deliver = {fillType = best.fillType, destination = trigger, bin = best.info.bin, strict = true, markerId = marker.id}
    ADAddOn.log(vehicle, "%s l %s on board: to the robot's %s bin at '%s'", tostring(ADAddOn.getLoaded(vehicle, best.fillType)),
        getFillTypeName(best.fillType), best.info.title, ADAddOn.nameOf(bestBarn.placeable))
end

function ADAddOn.planTrip(mode)
    local vehicle = mode.vehicle
    local spec = getSpec(vehicle)
    spec.job = nil

    local stateModule = vehicle.ad.stateModule
    if stateModule:getFirstMarker() == nil or stateModule:getSecondMarker() == nil then
        ADAddOn.log(vehicle, "not planned: 1st target %s, 2nd target %s", tostring(stateModule:getFirstMarker() ~= nil), tostring(stateModule:getSecondMarker() ~= nil))
        return nil
    end

    -- Bale Collection: Courseplay + AutoDrive's helper hand-over; the pickup is the field, not a storage
    if spec.mode == ADAddOnSpec.MODE_BALES then
        if not ADAddOn.canCollectBales(vehicle) then
            warnOnce(vehicle, "noBaler", "this vehicle can't collect bales with Courseplay, driving as normal AutoDrive.")
        end
        ADAddOn.ensureBaleHelper(vehicle)
        return nil
    end
    -- Repair/Refill: not built yet, plain AutoDrive
    if spec.mode == ADAddOnSpec.MODE_REPAIR_REFILL then
        return nil
    end
    if stateModule:getCanRestartHelper() or ADAddOn.AD.AutoDrive:getIsCPActive(vehicle) then
        -- AutoDrive's helper button (Courseplay / AI) is on: AutoDrive hands this run to that helper
        warnOnce(vehicle, "helper", "AutoDrive's helper button (Courseplay / AI) is on for this vehicle, so the load is not limited. Switch it off for Fill Robot / Milk Transport.")
        ADAddOn.log(vehicle, "not planned: AutoDrive helper restart on (%s), Courseplay active (%s)", tostring(stateModule:getCanRestartHelper()), tostring(ADAddOn.AD.AutoDrive:getIsCPActive(vehicle)))
        return nil
    end

    local farmId = vehicle:getOwnerFarmId()
    if spec.mode == ADAddOnSpec.MODE_MILK then
        return ADAddOn.planMilk(mode, farmId)
    end
    if spec.mode == ADAddOnSpec.MODE_TOP_OFF then
        local fillType = stateModule:getFillType()
        if fillType == nil or fillType == FillType.UNKNOWN or ADAddOn.isBale(fillType) then
            warnOnce(vehicle, "noTopOffType", "select the fill type to top off %s with.", stateModule:getSecondMarkerName())
            return nil
        end
        return ADAddOn.planTopOff(mode, fillType, farmId, true)
    end

    -- Fill Robot
    local result, stopMessage = ADAddOn.planRobotRun(mode, farmId)
    if result == false then
        -- no robot at the 2nd target: stop here, never drive to a barn without a feeding robot
        ADAddOn.sendMessage(vehicle, true, "%s", stopMessage)
        return finishRun(mode)
    end
    if result ~= nil then
        return result
    end
    -- no robot barn reachable by an AutoDrive target: top off the 2nd target with the selected feed
    if spec.firstTargetFilledIn then
        ADAddOn.sendMessage(vehicle, true, "no AutoDrive target leads over a feeding robot tipping point at %s. Set the 1st target by hand. Stopped.",
            stateModule:getSecondMarkerName())
        return finishRun(mode)
    end
    local fillType = stateModule:getFillType()
    if fillType == nil or fillType == FillType.UNKNOWN or ADAddOn.isBale(fillType) or ADAddOn.isMilk(fillType) then
        warnOnce(vehicle, "noFeed", "no robot barn found; select the feed to top off the 2nd target with.")
        return nil
    end
    if ADAddOn.isMineralFeed(fillType) then
        warnOnce(vehicle, "mineral", "mineral feed is left to normal AutoDrive.")
        return nil
    end
    return ADAddOn.planTopOff(mode, fillType, farmId)
end

-- AutoDrive's own isa() errors on any task that isn't the one asked for (it walks up to AbstractTask, which has no
-- superClass), so compare the class directly
local function isLoadTask(task)
    return task ~= nil and task.class ~= nil and task:class() == ADAddOn.AD.LoadAtDestinationTask
end

local function isUnloadTask(task)
    return task ~= nil and task.class ~= nil and task:class() == ADAddOn.AD.UnloadAtDestinationTask
end

function ADAddOn.getNextTask(mode, superFunc, forced)
    local task = superFunc(mode, forced)
    if ADAddOn.isReady and g_server ~= nil and isLoadTask(task) and ADAddOn.isOn(mode.vehicle) and mode.vehicle.ad ~= nil then
        local result = ADAddOn.planTrip(mode)
        if type(result) == "table" then
            ADAddOn.log(mode.vehicle, "run finished, AutoDrive stops")
            return result
        elseif result == nil then
            ADAddOn.log(mode.vehicle, "pickup trip with fill type %s: not limited, normal AutoDrive", getFillTypeName(mode.vehicle.ad.stateModule:getFillType() or 0))
        elseif getSpec(mode.vehicle).job ~= nil and getSpec(mode.vehicle).job.markerId ~= nil then
            -- fill feeding robot: the storage ADAddOn chose
            task.destinationID = getSpec(mode.vehicle).job.markerId
        end
    elseif getSpec(mode.vehicle) ~= nil and not isLoadTask(task) then
        -- only a pickup trip carries a load target
        local spec = getSpec(mode.vehicle)
        spec.job = nil
        if ADAddOn.isReady and g_server ~= nil and spec.isOn and isUnloadTask(task) and mode.vehicle.ad ~= nil
            and not ADAddOnSpec.isFillRobotMode(spec.mode) and spec.deliver ~= nil then
            -- last check before the delivery trip (user's rule, every mode but Fill Robot): no trip for a load under
            -- the minimum (1.5 % of what the vehicle holds), whatever the pickup really gave
            local fillType = spec.deliver.fillType
            local loaded = ADAddOn.getLoaded(mode.vehicle, fillType)
            -- the vehicle's own 1.5 % only: the target's share is a planning rule, and a weight limit can stop a
            -- planned full load short of it
            -- (and never stricter than the planned minimum, which is smaller on a small target)
            -- (and never stricter than the source floor: Top It Off / Milk empty the source down to MIN_SOURCE)
            local minTrip = math.min(ADAddOn.getMinTrip(ADAddOn.getCapacity(mode.vehicle, fillType)), spec.deliver.minTrip or math.huge,
                spec.deliver.sourceMin or math.huge)
            if loaded < minTrip then
                ADAddOn.log(mode.vehicle, "delivery trip refused: %s l %s on board, minimum trip %s l", tostring(loaded), getFillTypeName(fillType), tostring(minTrip))
                ADAddOn.sendMessage(mode.vehicle, true, "only %s of %s on board, not worth the trip (minimum %s). Stopped.",
                    formatLiters(loaded), getFillTypeTitle(fillType), formatLiters(minTrip))
                return finishRun(mode)
            end
        end
        if ADAddOn.isReady and g_server ~= nil and spec.isOn and isUnloadTask(task) and mode.vehicle.ad ~= nil then
            if spec.deliver == nil and ADAddOnSpec.isFillRobotMode(spec.mode) then
                -- started with feed on board
                ADAddOn.planRobotDelivery(mode, mode.vehicle:getOwnerFarmId())
            end
            if spec.deliver ~= nil and spec.deliver.markerId ~= nil then
                -- fill feeding robot: the robot bin ADAddOn chose (also over AutoDrive's folder rotation / best price)
                task.destinationID = spec.deliver.markerId
            end
        end
    end
    return task
end

-- planned amount on board: AutoDrive must not try to load again. It would, every few seconds, as long as the truck
-- isn't full, and it holds the truck still while it tries (in game 2026-11-01: a part load stopped right, then the
-- truck stood at the fermenter until the player pressed continue)
function ADAddOn.trailerUpdateLoad(trailerModule, superFunc, dt)
    local vehicle = trailerModule.vehicle
    local spec = getSpec(vehicle)
    local job = spec ~= nil and spec.job or nil
    if job ~= nil and g_server ~= nil and ADAddOn.getLoaded(vehicle, job.fillType) >= job.loadTarget - ADAddOn.MIN_AMOUNT then
        if trailerModule.trigger ~= nil and trailerModule.trigger.isLoading and trailerModule.trigger.setIsLoading ~= nil then
            trailerModule.trigger:setIsLoading(false)
        end
        trailerModule.isLoading = false
        trailerModule.trigger = nil
        return
    end
    return superFunc(trailerModule, dt)
end

-- at the pickup: leave as soon as the planned amount is on board or the source is empty, never wait for "full"
function ADAddOn.loadTaskUpdate(task, superFunc, dt)
    local vehicle = task.vehicle
    local spec = getSpec(vehicle)
    local job = spec ~= nil and spec.job or nil
    if job ~= nil and g_server ~= nil and task.state == ADAddOn.AD.LoadAtDestinationTask.STATE_DRIVING
        and vehicle.ad.drivePathModule:isTargetReached() and (job.source == nil or not job.source.isLoading) then
        local loaded = ADAddOn.getLoaded(vehicle, job.fillType)
        if loaded >= job.loadTarget - ADAddOn.MIN_AMOUNT
            or (job.source ~= nil and not job.fromBuyingStation and ADAddOn.getSourceLevel(job.source, job.fillType, vehicle:getOwnerFarmId()) < ADAddOn.MIN_AMOUNT) then
            ADAddOn.log(vehicle, "leaving the pickup with %s l %s (planned %s)", tostring(loaded), getFillTypeName(job.fillType), tostring(job.loadTarget))
            if job.buying and spec.robotRun ~= nil then
                local run = spec.robotRun
                local bought = loaded - (job.loadedBefore or 0)
                -- liters bought x the station's price: other income or costs of the farm during the trip don't count
                local cost
                if job.price ~= nil then
                    cost = math.max(0, bought) * job.price
                else
                    local after = ADAddOn.getMoney(vehicle:getOwnerFarmId())
                    cost = (job.moneyBefore ~= nil and after ~= nil) and math.max(0, job.moneyBefore - after) or 0
                end
                run.bought = run.bought + bought
                run.spentTotal = run.spentTotal + cost
                ADAddOn.sendMessage(vehicle, false, "bought %s of %s for %s (%s this run, %s).", formatLiters(bought), getFillTypeTitle(job.fillType),
                    formatMoney(cost), formatMoney(run.spentTotal), job.barnName or "?")
                job.buying = false
            end
            vehicle.ad.trailerModule:stopLoading()
            task:finished()
            return
        end
    end
    return superFunc(task, dt)
end

-- at the destination: if the load can't all go in (destination full, load left on board), stop with a message
-- instead of sitting there waiting
function ADAddOn.unloadTaskUpdate(task, superFunc, dt)
    superFunc(task, dt)

    local vehicle = task.vehicle
    local spec = getSpec(vehicle)
    local deliver = spec ~= nil and spec.isOn and spec.deliver or nil
    if deliver == nil or g_server == nil or vehicle.ad == nil or task.state ~= ADAddOn.AD.UnloadAtDestinationTask.STATE_DRIVING
        or not vehicle.ad.drivePathModule:isTargetReached() then
        if spec ~= nil then
            spec.fullTime = 0
            spec.wrongSpotTime = 0
        end
        return
    end

    local loaded = ADAddOn.getLoaded(vehicle, deliver.fillType)
    local free = deliver.bin ~= nil and math.max(0, deliver.bin.capacity - deliver.bin.fillLevel)
        or ADAddOn.getFreeCapacity(deliver.destination, deliver.fillType, vehicle:getOwnerFarmId())

    -- robot run, stopped at the pin with load on board, but the trailer is not over the robot's tipping point
    if deliver.strict and loaded >= ADAddOn.MIN_AMOUNT and free >= ADAddOn.MIN_AMOUNT then
        local object = ADAddOn.getDischargeObject(vehicle, deliver.fillType)
        if not isSameDestination(object, deliver.destination) then
            spec.wrongSpotTime = (spec.wrongSpotTime or 0) + dt
            if spec.wrongSpotTime >= ADAddOn.FULL_WAIT then
                ADAddOn.log(vehicle, "at the 2nd target the trailer is over '%s', not the robot's storage, stopping", ADAddOn.nameOf(object))
                ADAddOn.sendMessage(vehicle, true, "the trailer is not at the robot's %s tipping point at %s. Move the 2nd target pin so the trailer stops over it. Stopped.",
                    getFillTypeTitle(deliver.fillType), vehicle.ad.stateModule:getSecondMarkerName())
                spec.deliver = nil
                spec.wrongSpotTime = 0
                vehicle:stopAutoDrive()
                vehicle:setADAddOn(false)
            end
            return
        end
    end
    spec.wrongSpotTime = 0

    if loaded >= ADAddOn.MIN_AMOUNT and free < ADAddOn.MIN_AMOUNT then
        spec.fullTime = (spec.fullTime or 0) + dt
        if spec.fullTime >= ADAddOn.FULL_WAIT then
            ADAddOn.log(vehicle, "destination '%s' full with %s l %s still on board, stopping", ADAddOn.nameOf(deliver.destination), tostring(loaded), getFillTypeName(deliver.fillType))
            spec.deliver = nil
            spec.fullTime = 0
            if spec.mode == ADAddOnSpec.MODE_TOP_OFF then
                -- Top It Off: the tip got filled from somewhere else, the button switches itself off
                ADAddOn.sendMessage(vehicle, true, "Overfill detected.")
                vehicle:stopAutoDrive()
                vehicle:setADAddOn(false)
                return
            end
            ADAddOn.sendMessage(vehicle, true, "%s is full, %s of %s still on board. Stopped.", vehicle.ad.stateModule:getSecondMarkerName(), formatLiters(loaded), getFillTypeTitle(deliver.fillType))
            vehicle:stopAutoDrive()
            vehicle:setADAddOn(false)
        end
    else
        spec.fullTime = 0
    end
end

-- the load trigger stops at exactly the planned amount
function ADAddOn.loadTriggerUpdate(trigger, superFunc, dt)
    if trigger.isServer and trigger.isLoading and trigger.currentFillableObject ~= nil and trigger.currentFillableObject.getRootVehicle ~= nil then
        local vehicle = trigger.currentFillableObject:getRootVehicle()
        local spec = getSpec(vehicle)
        local job = spec ~= nil and spec.job or nil
        if job ~= nil and job.fillType == trigger.selectedFillType then
            local loadedNow = ADAddOn.getLoaded(vehicle, job.fillType)
            local remaining = job.loadTarget - loadedNow
            if remaining < ADAddOn.MIN_AMOUNT then
                trigger:setIsLoading(false)
                return
            end

            local fillSpeed = trigger.fillLitersPerMS
            if trigger.currentFillableObject.getLoadTriggerMaxFillSpeed ~= nil then
                fillSpeed = math.min(fillSpeed, trigger.currentFillableObject:getLoadTriggerMaxFillSpeed())
            end
            local delta = fillSpeed * dt
            if trigger.useTimeScale then
                delta = delta * g_currentMission:getEffectiveTimeScale()
            end
            if delta >= remaining then
                -- last bit of the load: only what's missing, then stop
                ADAddOn.log(vehicle, "load trigger stopped at the planned %s l", tostring(job.loadTarget))
                trigger.source:addFillLevelToFillableObject(trigger.currentFillableObject, trigger.fillUnitIndex, trigger.selectedFillType, remaining, trigger.dischargeInfo, ToolType.TRIGGER)
                trigger:setIsLoading(false)
                trigger:raiseActive()
                return
            end
        end
    end
    return superFunc(trigger, dt)
end

------------------------------------------------------------------------------------------------------------------------
-- Repair/Refill mode: button ON -> the vehicle drives to a repair site and a diesel refuel site (the closer one first),
-- using AutoDrive's own RepairTask / RefuelTask (the same trips as AutoDrive's repair / refuel buttons). ADAddOn only
-- picks the sites and the order; the hooks below hand AutoDrive those sites while a run is on.
--   repair site: AutoDrive's own pick (a workshop of the vehicle's farm first, else the nearest one with a pin)
--   refuel site: the farm's own diesel storage (tank, silo, production) -> a buying station of the farm that sells diesel
--                -> the nearest diesel station on the map. Diesel only; electric / methane: not supported yet.
--   skipped when everything attached is in 95 % condition or better / the tank is 95 % full or more.
-- After the last stop: the AutoDrive parking position if set (AutoDrive's own park button), else it stays; button OFF.
------------------------------------------------------------------------------------------------------------------------

ADAddOn.RR_GOOD = 0.95
-- AutoDrive stopped during a stop and didn't finish it (no path, player stopped it): end the run after this long
ADAddOn.RR_STOP_WAIT = 3000

-- vehicles whose run goes on to the next stop on the next update (out of AutoDrive's task code first)
ADAddOn.rrPending = setmetatable({}, {__mode = "k"})
-- vehicles with a Repair/Refill run on
ADAddOn.rrRuns = setmetatable({}, {__mode = "k"})

local function rrStep(vehicle)
    local run = ADAddOn.rrRuns[vehicle]
    return run ~= nil and run.steps[run.index] or nil
end

-- worst condition (1 = like new) of the vehicle and everything attached
local function getWorstCondition(vehicle)
    local worst = 1
    for _, object in pairs(ADAddOn.AD.AutoDrive.getAllImplements(vehicle, true)) do
        local damage = nil
        if object.getDamageAmount ~= nil then
            damage = object:getDamageAmount()
        elseif object.spec_wearable ~= nil then
            damage = object.spec_wearable.damage
        end
        if type(damage) == "number" then
            worst = math.min(worst, 1 - damage)
        end
    end
    return worst
end

-- the vehicle's fuel: "diesel" + fill level share, "unsupported" (electric / methane), or nil (no motor)
local function getFuel(vehicle)
    local spec = vehicle.spec_motorized
    if spec == nil or spec.consumersByFillTypeName == nil then
        return nil
    end
    for name, consumer in pairs(spec.consumersByFillTypeName) do
        local upper = string.upper(tostring(name))
        if upper == "DIESEL" then
            return "diesel", vehicle:getFillUnitFillLevelPercentage(consumer.fillUnitIndex)
        end
    end
    for name, _ in pairs(spec.consumersByFillTypeName) do
        local upper = string.upper(tostring(name))
        if upper == "ELECTRICCHARGE" or upper == "METHANE" then
            return "unsupported"
        end
    end
    return nil
end

local function isVehicleTrigger(trigger)
    return trigger.triggerNode ~= nil and entityExists(trigger.triggerNode)
        and CollisionFlag.getHasMaskFlagSet(trigger.triggerNode, CollisionFlag.FILLABLE) and CollisionFlag.getHasGroupFlagSet(trigger.triggerNode, CollisionFlag.TRIGGER)
end

-- the pin AutoDrive's refuel trip can use for a trigger: the nearest map marker within MAX_REFUEL_TRIGGER_DISTANCE
local function getRefuelPin(trigger)
    local AD = ADAddOn.AD
    local x, _, z = AD.ADTriggerManager.getTriggerPos(trigger)
    if x == nil or (x == 0 and z == 0) then
        return nil
    end
    local maxDistance = AD.AutoDrive.MAX_REFUEL_TRIGGER_DISTANCE or 15
    local bestIndex, bestMarker, bestDistance = nil, nil, maxDistance
    for markerIndex, mapMarker in pairs(AD.ADGraphManager:getMapMarkers()) do
        local wayPoint = AD.ADGraphManager:getWayPointById(mapMarker.id)
        if wayPoint ~= nil then
            local distance = MathUtil.vector2Length(wayPoint.x - x, wayPoint.z - z)
            if distance < bestDistance then
                bestIndex, bestMarker, bestDistance = markerIndex, mapMarker, distance
            end
        end
    end
    return bestIndex, bestMarker
end

local function distanceTo(vehicle, wayPointId)
    local wayPoint = ADAddOn.AD.ADGraphManager:getWayPointById(wayPointId)
    if wayPoint == nil then
        return math.huge
    end
    local x, _, z = getWorldTranslation(vehicle.components[1].node)
    return MathUtil.vector2Length(wayPoint.x - x, wayPoint.z - z)
end

-- the diesel refuel site: {trigger, markerIndex, wayPointId, tier, name} or nil
function ADAddOn.findRefuelSite(vehicle)
    local farmId = vehicle:getOwnerFarmId()
    local diesel = FillType.DIESEL
    local best, bestTier, bestDistance = nil, math.huge, math.huge
    for _, trigger in pairs(ADAddOn.AD.ADTriggerManager.getLoadTriggers()) do
        if trigger.fillTypes ~= nil and trigger.fillTypes[diesel] and trigger.source ~= nil and trigger.source.getAllFillLevels ~= nil
            and isVehicleTrigger(trigger) then
            local kind = getSourceKind(trigger, farmId)
            -- 1 = the farm's own diesel (tank / silo / production), 2 = the farm's buying station, 3 = anywhere on the map
            local tier = (kind == "silo" or kind == "production") and 1 or (kind == "buy" and 2 or 3)
            local level = ADAddOn.getSourceLevel(trigger, diesel, farmId)
            if level > 0 and tier <= bestTier then
                local markerIndex, marker = getRefuelPin(trigger)
                if marker ~= nil then
                    local distance = distanceTo(vehicle, marker.id)
                    if tier < bestTier or distance < bestDistance then
                        best = {trigger = trigger, markerIndex = markerIndex, wayPointId = marker.id, tier = tier, name = marker.name}
                        bestTier, bestDistance = tier, distance
                    end
                end
            end
        end
    end
    return best
end

-- the repair site: AutoDrive's own choice (the farm's workshop first, else the nearest), {wayPointId, name} or nil
function ADAddOn.findRepairSite(vehicle)
    local AD = ADAddOn.AD
    local found = AD.AutoDrive.getClosestRepairTrigger(AD.AutoDrive, vehicle)
    if found == nil or found.marker == nil then
        return nil
    end
    local mapMarker = AD.ADGraphManager:getMapMarkerByWayPointId(found.marker)
    return {wayPointId = found.marker, name = mapMarker ~= nil and mapMarker.name or "?"}
end

-- button ON in Repair/Refill: work out the stops and start the first one
function ADAddOn.startRepairRefill(vehicle)
    local stateModule = vehicle.ad.stateModule
    local steps = {}

    local condition = getWorstCondition(vehicle)
    if condition < ADAddOn.RR_GOOD then
        local site = ADAddOn.findRepairSite(vehicle)
        if site ~= nil then
            table.insert(steps, {kind = "repair", site = site})
        else
            ADAddOn.sendMessage(vehicle, true, "No repair site found.")
        end
    else
        ADAddOn.log(vehicle, "repair/refill: condition %.0f %%, no repair needed", condition * 100)
    end

    local fuel, level = getFuel(vehicle)
    if fuel == "unsupported" then
        ADAddOn.sendMessage(vehicle, true, "Fuel type not supported at this time.")
    elseif fuel == "diesel" and level < ADAddOn.RR_GOOD then
        local site = ADAddOn.findRefuelSite(vehicle)
        if site ~= nil then
            table.insert(steps, {kind = "refuel", site = site})
        else
            ADAddOn.sendMessage(vehicle, true, "No refuel site found.")
        end
    elseif fuel == "diesel" then
        ADAddOn.log(vehicle, "repair/refill: tank %.0f %% full, no refuel needed", level * 100)
    end

    if #steps == 0 then
        if condition >= ADAddOn.RR_GOOD and (fuel ~= "diesel" or level >= ADAddOn.RR_GOOD) then
            ADAddOn.sendMessage(vehicle, false, "nothing to repair or refuel (95 %% or better).")
        end
        vehicle:setADAddOn(false)
        return
    end

    -- refuel first, then repair (user's rule 2026-11-15)
    table.sort(steps, function(a, b)
        return a.kind == "refuel" and b.kind ~= "refuel"
    end)
    for i, step in ipairs(steps) do
        ADAddOn.log(vehicle, "repair/refill stop %d: %s at '%s' (%.0f m)%s", i, step.kind, tostring(step.site.name),
            distanceTo(vehicle, step.site.wayPointId), step.site.tier ~= nil and string.format(", refuel choice %d", step.site.tier) or "")
    end

    local first = stateModule:getFirstMarker()
    ADAddOn.rrRuns[vehicle] = {steps = steps, index = 0, oldMode = stateModule:getMode(),
        oldFirstId = first ~= nil and first.id or nil}
    if stateModule:isActive() then
        vehicle.ad.isStoppingWithError = false
        vehicle:stopAutoDrive()
    end
    ADAddOn.rrPending[vehicle] = true
end

-- the next stop, or the end of the run
function ADAddOn.nextRepairRefillStep(vehicle)
    local AD = ADAddOn.AD
    local run = ADAddOn.rrRuns[vehicle]
    if run == nil then
        return
    end
    local stateModule = vehicle.ad.stateModule
    vehicle.ad.onRouteToRepair = false
    vehicle.ad.onRouteToRefuel = false
    run.index = run.index + 1
    local step = run.steps[run.index]
    if step == nil then
        ADAddOn.endRepairRefill(vehicle, true)
        return
    end
    run.stepStarted = g_currentMission.time
    run.stepDone = false
    -- AutoDrive's own repair / refuel button way: Drive To mode with the trip flag; the task module then starts
    -- RepairTask / RefuelTask to the site the hooks hand it. The 1st target is set to the site so Drive To starts.
    stateModule:setFirstMarkerByWayPointId(step.site.wayPointId)
    stateModule:setMode(AD.AutoDrive.MODE_DRIVETO)
    if step.kind == "repair" then
        vehicle.ad.onRouteToRepair = true
    else
        vehicle.ad.onRouteToRefuel = true
    end
    ADAddOn.log(vehicle, "repair/refill: driving to %s at '%s'", step.kind, tostring(step.site.name))
    AD.ADInputManager:input_start_stop(vehicle, vehicle:getOwnerFarmId())
end

function ADAddOn.endRepairRefill(vehicle, done, text)
    local run = ADAddOn.rrRuns[vehicle]
    ADAddOn.rrRuns[vehicle] = nil
    ADAddOn.rrPending[vehicle] = nil
    if vehicle.ad == nil then
        return
    end
    vehicle.ad.onRouteToRepair = false
    vehicle.ad.onRouteToRefuel = false
    local stateModule = vehicle.ad.stateModule
    if run ~= nil then
        -- the player's own targets back
        if run.oldMode ~= nil then
            stateModule:setMode(run.oldMode)
        end
        if run.oldFirstId ~= nil then
            stateModule:setFirstMarkerByWayPointId(run.oldFirstId)
        end
    end
    if text ~= nil then
        ADAddOn.sendMessage(vehicle, not done, text)
    elseif done then
        ADAddOn.sendMessage(vehicle, false, "refuel/repair done.")
    end
    if ADAddOn.isOn(vehicle) then
        vehicle:setADAddOn(false)
    end
    if done and ADAddOn.getParkMarker(vehicle) ~= nil then
        ADAddOn.log(vehicle, "repair/refill done, driving to the parking position")
        ADAddOn.AD.ADInputManager:input_parkVehicle(vehicle, vehicle:getOwnerFarmId())
    end
end

-- called every update while runs are on
function ADAddOn.updateRepairRefill()
    for vehicle, _ in pairs(ADAddOn.rrPending) do
        ADAddOn.rrPending[vehicle] = nil
        if vehicle.isDeleted or vehicle.ad == nil then
            ADAddOn.rrRuns[vehicle] = nil
        else
            ADAddOn.nextRepairRefillStep(vehicle)
        end
    end
    for vehicle, run in pairs(ADAddOn.rrRuns) do
        if vehicle.isDeleted or vehicle.ad == nil then
            ADAddOn.rrRuns[vehicle] = nil
        elseif not ADAddOn.rrPending[vehicle] and run.stepStarted ~= nil and not vehicle.ad.stateModule:isActive()
            and g_currentMission.time - run.stepStarted > ADAddOn.RR_STOP_WAIT then
            -- AutoDrive stopped without finishing the stop (no path, stopped by the player)
            local step = run.steps[run.index]
            ADAddOn.endRepairRefill(vehicle, false, string.format("refuel/repair stopped: AutoDrive did not get to the %s site.",
                step ~= nil and step.kind or "?"))
        end
    end
end

-- hooks: while a run is on, AutoDrive's task module only does this vehicle's current stop, at the site ADAddOn picked
function ADAddOn.hasToRepair(taskModule, superFunc)
    local step = rrStep(taskModule.vehicle)
    if ADAddOn.rrRuns[taskModule.vehicle] ~= nil then
        return step ~= nil and step.kind == "repair" and taskModule.vehicle.ad.onRouteToRepair == true
    end
    return superFunc(taskModule)
end

function ADAddOn.hasToRefuel(taskModule, superFunc)
    local step = rrStep(taskModule.vehicle)
    if ADAddOn.rrRuns[taskModule.vehicle] ~= nil then
        return step ~= nil and step.kind == "refuel" and taskModule.vehicle.ad.onRouteToRefuel == true
    end
    return superFunc(taskModule)
end

function ADAddOn.getClosestRepairTrigger(autoDrive, superFunc, vehicle)
    local step = vehicle ~= nil and rrStep(vehicle) or nil
    if step ~= nil and step.kind == "repair" then
        return {marker = step.site.wayPointId, distance = distanceTo(vehicle, step.site.wayPointId)}
    end
    return superFunc(autoDrive, vehicle)
end

-- (these three are called with a dot: Utils.overwrittenFunction passes the vehicle first, then superFunc)
function ADAddOn.getClosestRefuelDestination(vehicle, superFunc, ignoreFillLevel)
    local step = vehicle ~= nil and rrStep(vehicle) or nil
    if step ~= nil and step.kind == "refuel" then
        return step.site.markerIndex
    end
    return superFunc(vehicle, ignoreFillLevel)
end

function ADAddOn.getClosestRefuelTrigger(vehicle, superFunc, ignoreFillLevel)
    local step = vehicle ~= nil and rrStep(vehicle) or nil
    if step ~= nil and step.kind == "refuel" then
        return step.site.trigger
    end
    return superFunc(vehicle, ignoreFillLevel)
end

-- the refuel stop fills diesel only, up to the 95 % rule (AutoDrive's own rule is 90 %)
function ADAddOn.getRequiredRefuels(vehicle, superFunc, ignoreFillLevel)
    if vehicle ~= nil and ADAddOn.rrRuns[vehicle] ~= nil then
        local step = rrStep(vehicle)
        if step ~= nil and step.kind == "refuel" then
            local fuel, level = getFuel(vehicle)
            if fuel == "diesel" and level < ADAddOn.RR_GOOD then
                return {FillType.DIESEL}
            end
        end
        return {}
    end
    return superFunc(vehicle, ignoreFillLevel)
end

-- the stop is done: instead of AutoDrive restarting its Drive To mode, stop and go on to the next stop
function ADAddOn.repairTaskFinished(task, superFunc)
    if ADAddOn.rrRuns[task.vehicle] ~= nil then
        task.vehicle.ad.onRouteToRepair = false
        ADAddOn.log(task.vehicle, "repair/refill: repaired")
        task.vehicle.ad.isStoppingWithError = false
        task.vehicle:stopAutoDrive()
        ADAddOn.rrPending[task.vehicle] = true
        return
    end
    return superFunc(task)
end

function ADAddOn.refuelTaskFinished(task, superFunc)
    if ADAddOn.rrRuns[task.vehicle] ~= nil then
        task.vehicle.ad.onRouteToRefuel = false
        task.refuelTrigger = nil
        task.wasRefuelling = false
        local _, level = getFuel(task.vehicle)
        ADAddOn.log(task.vehicle, "repair/refill: refuelled, tank %.0f %%", (level or 0) * 100)
        task.vehicle.ad.isStoppingWithError = false
        task.vehicle:stopAutoDrive()
        ADAddOn.rrPending[task.vehicle] = true
        return
    end
    return superFunc(task)
end

function ADAddOn.installRepairRefillHooks()
    local AD = ADAddOn.AD
    for _, name in ipairs({"RepairTask", "RefuelTask", "ADInputManager"}) do
        if AD[name] == nil then
            Logging.warning("[ADAddOn] AutoDrive's %s not found: Repair/Refill disabled", name)
            return false
        end
    end
    AD.ADTaskModule.hasToRepair = Utils.overwrittenFunction(AD.ADTaskModule.hasToRepair, ADAddOn.hasToRepair)
    AD.ADTaskModule.hasToRefuel = Utils.overwrittenFunction(AD.ADTaskModule.hasToRefuel, ADAddOn.hasToRefuel)
    AD.AutoDrive.getClosestRepairTrigger = Utils.overwrittenFunction(AD.AutoDrive.getClosestRepairTrigger, ADAddOn.getClosestRepairTrigger)
    AD.ADTriggerManager.getClosestRefuelDestination = Utils.overwrittenFunction(AD.ADTriggerManager.getClosestRefuelDestination, ADAddOn.getClosestRefuelDestination)
    AD.ADTriggerManager.getClosestRefuelTrigger = Utils.overwrittenFunction(AD.ADTriggerManager.getClosestRefuelTrigger, ADAddOn.getClosestRefuelTrigger)
    AD.AutoDrive.getRequiredRefuels = Utils.overwrittenFunction(AD.AutoDrive.getRequiredRefuels, ADAddOn.getRequiredRefuels)
    AD.RepairTask.finished = Utils.overwrittenFunction(AD.RepairTask.finished, ADAddOn.repairTaskFinished)
    AD.RefuelTask.finished = Utils.overwrittenFunction(AD.RefuelTask.finished, ADAddOn.refuelTaskFinished)
    ADAddOn.repairRefillReady = true
    return true
end

addModEventListener(ADAddOn)
