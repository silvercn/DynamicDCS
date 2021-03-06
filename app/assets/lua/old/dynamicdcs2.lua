clientEventHandler = {}

function tprint (tbl, indent)
	if not indent then indent = 0 end
	for k, v in pairs(tbl) do
		formatting = string.rep("  ", indent) .. k .. ": "
		if type(v) == "table" then
			env.info(formatting)
			--tprint(v, indent+1)
		elseif type(v) == 'boolean' then
			env.info(formatting .. tostring(v))
		else
			env.info(formatting .. tostring(v))
		end
	end
end

do
    --
    local PORT = 3011
    local DATA_TIMEOUT_SEC = 0.5

	local cacheDB = {}
	local updateQue = {["que"] = {}}

    package.path = package.path..";.\\LuaSocket\\?.lua"
    package.cpath = package.cpath..";.\\LuaSocket\\?.dll"

	--in missionScripting.lua file: dynamicDCS = { require = require }
    require = dynamicDCS.require
    local socket = require("socket")
    local JSON = loadfile("Scripts\\JSON.lua")()
    require = nil

    local function log(msg)
        env.info("DynamicDCS (t=" .. timer.getTime() .. "): " .. msg)
    end

	local function clearVar()
		cacheDB = {}
		updateQue = {["que"] = {}}
	end

    local function getDataMessage()
		local checkDead = {}

		--unit updating system unit, unitID, coalition, lat, lon, alt, hdg, speed, action
        local function addUnit(unit, unitID, coalition, lat, lon, alt, hdg, speed, category, action)
            local curUnit = {
                action = action,
                data = {
					unitID = unitID
				}
            }
            if action == "C" or action == "U" then
                cacheDB[unitID] = {}
                cacheDB[unitID].lat = lat
                cacheDB[unitID].lon = lon
				cacheDB[unitID].alt = alt
				cacheDB[unitID].hdg = hdg
				cacheDB[unitID].speed = speed
                curUnit.data.lat = lat
                curUnit.data.lon = lon
				curUnit.data.alt = alt
				curUnit.data.hdg = hdg
				curUnit.data.speed = speed
                if action == "C" then
                    curUnit.data.type = unit:getTypeName()
                    curUnit.data.coalition = coalition
					curUnit.data.category = category
                    local PlayerName = unit:getPlayerName()
                    if PlayerName ~= nil then
                        curUnit.data.playername = PlayerName
                    else
                        curUnit.data.playername = ""
                    end
                end
            end
            table.insert(updateQue.que, curUnit)
        end

		local CategoryNames = {
			[Unit.Category.AIRPLANE] = "Airplane",
			[Unit.Category.HELICOPTER] = "Helicopter",
			[Unit.Category.GROUND_UNIT] = "Ground Unit",
			[Unit.Category.SHIP] = "Ship",
			[Unit.Category.STRUCTURE] = "Structure",
		}

        local function addGroups(groups, coalition)
            for groupIndex = 1, #groups do
                local group = groups[groupIndex]
                local units = group:getUnits()
                for unitIndex = 1, #units do
                    local unit = units[unitIndex]
                    --check against cache table (keep tabs on if unit is new to table, if table has unit that no longer exists or if unit moved
                     if Unit.isActive(unit) then
						 local category = CategoryNames[unit:getDesc().category]
						 local unitPosition = unit:getPosition()
						 local lat, lon, alt = coord.LOtoLL(unitPosition.p)
						 local unitID = tonumber(unit:getID())
						 local unitXYZNorthCorr = coord.LLtoLO(lat + 1, lon)
						 local headingNorthCorr = math.atan2(unitXYZNorthCorr.z - unitPosition.p.z, unitXYZNorthCorr.x - unitPosition.p.x)
						 local heading = math.atan2(unitPosition.x.z, unitPosition.x.x) + headingNorthCorr
						 if heading < 0 then
							 heading = heading + 2 * math.pi
						 end
						 local hdg = math.floor(heading / math.pi * 180);
						 local velocity = unit:getVelocity()
						 local speed = math.sqrt(velocity.x^2 + velocity.z^2)
                         if cacheDB[unitID] ~= nil then
                             --log('cachelat: '..cacheDB[unitID].lat..' reg lat: '..lat..' cachelon: '..cacheDB[unitID].lon..' reg lon: '..lon)
                             if cacheDB[unitID].lat ~= lat or cacheDB[unitID].lon ~= lon then
                                 addUnit(unit, unitID, coalition, lat, lon, alt, hdg, speed, category, "U")
                             end
                         else
                             addUnit(unit, unitID, coalition, lat, lon, alt, hdg, speed, category, "C")
                         end
                         checkDead[unitID] = 1
                    end
                end
            end
        end

        local redGroups = coalition.getGroups(coalition.side.RED)
        addGroups(redGroups, 1)
        local blueGroups = coalition.getGroups(coalition.side.BLUE)
        addGroups(blueGroups, 2)

        --check dead, send delete action to server if dead detected
        local unitCnt = 0
        for k, v in pairs( cacheDB ) do
            if checkDead[k] == nil then
                addUnit(0, k, 0, 0, 0, 0, 0, 0, '', "D")
				cacheDB[k] = nil
            end
            unitCnt = unitCnt + 1
		end

		--send base info, working off unitAccess.state for now
		table.insert(updateQue.que, {
			action = "baseInfo",
			data = unitAccess.state
		})


		local chkSize = 500
		local payload = {}
		payload.que = {}
		for i = 1,chkSize do
			table.insert(payload.que, updateQue.que[i])
			table.remove(updateQue.que, i)
		end
        payload.unitCount = unitCnt
		payload.startAbsTime = timer.getTime0()
		payload.curAbsTime = timer.getAbsTime()
        return payload
    end

	local function runRequest(request)
		env.info(request);
		if request.action ~= nil then
			if request.action == "INIT" then
				log('RUNNING REQUEST INIT')
				clearVar();
			end
			if request.action == "CMD" and request.cmd ~= nil and request.reqID ~= nil then
				log('RUNNING CMD')
				pcallCommand(request.cmd, request.reqID)
			end
		end
	end

    log("Starting DCS unit data server")

    local tcp = socket.tcp()
    local bound, error = tcp:bind('*', PORT)
    if not bound then
        log("Could not bind: " .. error)
        return
    end
    log("Port " .. PORT .. " bound")

    local serverStarted, error = tcp:listen(1)
    if not serverStarted then
        log("Could not start server: " .. error)
        return
    end
    log("Server started")

    local function checkJSON(jsonstring, code)
        if code == 'encode' then
            if type(JSON:encode(jsonstring)) ~= "string" then
                error("encode expects a string after function")
            end
        end
        if code == 'decode' then
            if type(jsonstring) ~= "string" then
                error("decode expects string")
            end
        end
    end

    local client
    local function step()

        if not client then
            tcp:settimeout(0.001)
            client = tcp:accept()

            if client then
                tcp:settimeout(0.001)
                log("Connection established")
				clearVar()
            end
        end

        if client then
           local line, err = client:receive()
           if line ~= nil then
               --log(line)
               local success, error =  pcall(checkJSON, line, 'decode')
               if success then
                   local incMsg = JSON:decode(line)
                   runRequest(incMsg);
               else
                   log("Error: " .. error)
               end
           end
            -- if there was no error, send it back to the client
            if not err then
                local dataPayload = getDataMessage()
                local success, error = pcall(checkJSON, dataPayload, 'encode')
                if success then
                    local outMsg = JSON:encode(dataPayload)
                    local bytes, status, lastbyte = client:send(outMsg.."\n")
                    if not bytes then
                        log("Connection lost")
                        client = nil
                    end;
                else
                    log("Error: " .. error)
                end
            else
                log("Connection lost")
                client = nil
            end
        end
    end

    timer.scheduleFunction(function(arg, time)
        local success, error = pcall(step)
        if not success then
            log("Error: " .. error)
        end
        return timer.getTime() + DATA_TIMEOUT_SEC
    end, nil, timer.getTime() + DATA_TIMEOUT_SEC)

    --Protected call to command execute
	function pcallCommand(s, respID)
		local success, resp =  pcall(commandExecute, s)
		if success then
			if resp ~= nil then
				local curUpdate;
				curUpdate = {
					action = 'CMDRESPONSE',
					data = {
						respID = respID,
						cmd = s,
						response = resp
					}
				}
				table.insert(updateQue.que, curUpdate)
			end
		else
			log("Error: " .. resp)
		end
	end

	function commandExecute(s)
		return loadstring("return " ..s)()
	end

	--Send Mission Events Back
	local eventTypes = {
		[0] = "S_EVENT_INVALID",
		[1] = "S_EVENT_SHOT",
		[2] = "S_EVENT_HIT",
		[3] = "S_EVENT_TAKEOFF",
		[4] = "S_EVENT_LAND",
		[5] = "S_EVENT_CRASH",
		[6] = "S_EVENT_EJECTION",
		[7] = "S_EVENT_REFUELING",
		[8] = "S_EVENT_DEAD",
		[9] = "S_EVENT_PILOT_DEAD",
		[10] = "S_EVENT_BASE_CAPTURED",
		[11] = "S_EVENT_MISSION_START",
		[12] = "S_EVENT_MISSION_END",
		[13] = "S_EVENT_TOOK_CONTROL",
		[14] = "S_EVENT_REFUELING_STOP",
		[15] = "S_EVENT_BIRTH",
		[16] = "S_EVENT_HUMAN_FAILURE",
		[17] = "S_EVENT_ENGINE_STARTUP",
		[18] = "S_EVENT_ENGINE_SHUTDOWN",
		[19] = "S_EVENT_PLAYER_ENTER_UNIT",
		[20] = "S_EVENT_PLAYER_LEAVE_UNIT",
		[21] = "S_EVENT_PLAYER_COMMENT",
		[22] = "S_EVENT_SHOOTING_START",
		[23] = "S_EVENT_SHOOTING_END",
		[24] = "S_EVENT_MAX"
	}
	local birthTypes = {
		"wsBirthPlace_Air",
		"wsBirthPlace_RunWay",
		"wsBirthPlace_Park",
		"wsBirthPlace_Heliport_Hot",
		"wsBirthPlace_Heliport_Cold"
	}

	local weaponCategory = {
		"SHELL",
		"MISSILE",
		"ROCKET",
		"BOMB"
	}


	function clientEventHandler:onEvent(_event)
		local status, err = pcall(
			function(_event)
				if _event == nil or _event.initiator == nil then
					return false
				else
					local curEvent = {}
					if _event.id ~= nil then
						curEvent.name = eventTypes[_event.id]
						curEvent.arg1 = _event.id
					end
					if _event.time ~= nil then
						curEvent.arg2 = _event.time
					end
					if _event.initiator ~= nil then
						curEvent.arg3 = tonumber(_event.initiator:getID())
					end
					if _event.target ~= nil then
						curEvent.arg4 = tonumber(_event.target:getID())
					end
					if _event.place ~= nil then
						curEvent.arg5 = _event.place:getName()
					end
					if _event.subPlace ~= nil then
						curEvent.arg6 = birthTypes[_event.subPlace]
					end
					if _event.weapon ~= nil then
						local curWeapon = _event.weapon:getDesc()
						curEvent.arg7 = {
							["typeName"] = curWeapon.typeName,
							["displayName"] = curWeapon.displayName,
							["category"] = weaponCategory[curWeapon.category + 1]
						}
					end
					--env.info('eventFiring: '..eventTypes[_event.id]);
					--env.info('curevent: '..curEvent.startAbsTime..' -- '..curEvent.curAbsTime);
					table.insert(updateQue.que, {
						action = eventTypes[_event.id],
						data = curEvent
					})
					return true
				end
			end
		, _event)
		if (not status) then
			env.info(string.format("Error while handling event %s", err), false)
		end
	end
end

world.addEventHandler(clientEventHandler)
env.info("dynamicDCS event handler added")
