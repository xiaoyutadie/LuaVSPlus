﻿local DebugPort = 16386
local DebugConnentTimeout = 20 -- 首次等待连接的时间
local DeBugON = true

if not DeBugON then return end

local socket = require("socket")
local HOOKMASK = "lcr"

if not setfenv then	-- Lua 5.2+
	local function findenv(f)
		local level = 1
		repeat
			local name, value = debug.getupvalue(f, level)
			if name == '_ENV' then return level, value end
			level = level + 1
		until name == nil
		return nil
	end
	getfenv = function(f)
		return (select(2, findenv(f)) or _G)
	end
	setfenv = function(f, t)
		local level = findenv(f)
		if level then debug.setupvalue(f, level, t) end
		return f
	end
end

if jit and jit.off then jit.off() end

local function leftShift(num, shift)
	return math.floor(num * (2 ^ shift));
end

local function rightShift(num, shift)
	return math.floor(num / (2 ^ shift));
end

local function toInt(msg)
	local a,b,c,d = string.byte(msg,1,4)
	return leftShift(d, 24) + leftShift(c, 16) + leftShift(b, 8) + a
end

local function toMsg(num)
	local str = ""
	str = str .. string.char(num % 256)
	str = str .. string.char(rightShift(num, 8) % 256)
	str = str .. string.char(rightShift(num, 16) % 256)
	str = str .. string.char(rightShift(num, 24) % 256)
	return str
end

local function toMsgWithStr(str)
	return toMsg(string.len(str)) .. str
end

local CommandKind = {
	Attach = 1,
	Detach = 2,
	Continue = 3,
	StepOver = 4,
	StepInto = 5,
	Break = 6,
	Evaluate = 7,
	AddBreakpoint = 8,
	RemoveBreakpoint = 9,
	DeleteAllBreakpoints = 10,
	SetBreakpointEnabled = 11,
	SetBreakpointCondition = 12, 
	SetBreakpointPassCount = 13,
	SetBreakpointHitCount = 14,  
	GetBreakpointHitCount = 15,
	LoadScriptDone = 16,
}

local EventKind = {
	InitializeDone = 1,
	LoadScript = 2,
	Break = 3,
	AddBreakpointDone = 4,
	Exception = 5,
	EvaluateDone = 6,
	Message = 7,
	Print = 8,
	GetBreakpointHitCountDone = 9,
	AttachDone = 10,
	DetachDone = 11,
}

local isAttaching = false
local socketCo

local serverSocket = nil
local clientSocket = nil
local scripts = nil
local scriptMap = nil
local curProcesser = nil
local curBreakLine = nil
local curBreakStackDepth = nil
local selfSource = nil

local function toXMLEscape(str)
	str = string.gsub(str, "&", "&amp;")
	str = string.gsub(str, "<", "&lt;")
	str = string.gsub(str, ">", "&gt;")
	str = string.gsub(str, "\"", "&quot;")
	str = string.gsub(str, "\'", "&apos;")
	return str
end

local function toXML(value, name,depth)
	local tStr = type(value)
	name = tostring(name)
	local st, vStr = pcall(tostring, value)
	local xml = string.format("<variable name=\"%s\" value=\"%s\" valueType=\"%s\">", toXMLEscape(name), toXMLEscape(vStr), tStr);
	if depth > 0 then
		if tStr == "table" then
			xml = xml .. "\n\t<children>\n\t\t"
			local mt = getmetatable(value)
			if mt then
				xml = xml .. toXML(mt, "__metatable", depth - 1)
			end
			local c = 0
			for n, v in pairs(value) do
				if type(v) ~= "function" then
					if c >= 50 then
						xml = xml .. "<variable name=\"...\" value=\"\" valueType=\"\"></variable>"
						break
					end
					if type(n) == "string" and tonumber(n) then
						n = string.format("\"%s\"",n)
					end
					xml = xml .. toXML(v, n, depth - 1)
					c = c + 1
				end
			end
			xml = xml .. "\n\t</children>\n"
		elseif tStr == "userdata" then
			xml = xml .. "\n\t<children>\n\t\t"
			local mt = getmetatable(value)
			if mt then
				xml = xml .. toXML(mt, "__metatable", depth - 1)
			end
			xml = xml .. "\n\t</children>\n"
		end
	end
	xml = xml .. "</variable>"
	return xml
end

local function evalute(expression, stackLevel)
	local statement = "return " .. expression
	local pf = loadstring(statement)
	if not pf then
		pf = loadstring(expression)
		if not pf then
			return false, "syntax err"
		end
	end
	local env = {}
	local func = (debug.getinfo(stackLevel, "f") or {}).func
	if func then
		local i = 1
		while true do
			local name, value = debug.getupvalue(func, i)
			if not name then break end
			if string.sub(name, 1, 1) ~= '(' then env[name] = value end
			i = i + 1
		end
		i = 1
		while true do
			local name, value = debug.getlocal(stackLevel, i)
			if not name then break end
			if string.sub(name, 1, 1) ~= '(' then env[name] = value end
			i = i + 1
		end
		setmetatable(env, {__index = getfenv(func), __newindex = getfenv(func), __mode = "v"})
	end
	setfenv(pf, env)
	local status, result = pcall(pf)
	return status, result
end

local function getStackDepth()
	local level = 1
	while debug.getinfo(level, "l") do
		level = level + 1
	end
	return level - 1
end


--@param #{isEnabled = isEnabled, condType = condType, condStr = condStr,passType = passType, passCount = passCount, hitCount = 0, hasValue = false} breakpoint
local function isBreakpointBreak(breakpoint)
	if not breakpoint.isEnabled then return false end
	local isHit = true
	if breakpoint.condType ~= 0 then -- CondNone
		local status, result = evalute(breakpoint.condStr, 5)
		if status then
			if breakpoint.condType == 1 then -- WhenTrue
				if result == false or result == nil then
					isHit =false
				end
			else
				if breakpoint.hasValue then
					isHit = breakpoint.curValue ~= result
				else
					breakpoint.hasValue = true
					isHit = false
				end
				breakpoint.curValue = result
			end
		else
			isHit = false
		end
	end
	if isHit then
		breakpoint.hitCount = breakpoint.hitCount + 1
		if breakpoint.passType == 1 then -- Equal
			isHit = breakpoint.hitCount == breakpoint.passCount
		elseif breakpoint.passType == 2 then  -- EqualOrGreater
			isHit = breakpoint.hitCount >= breakpoint.passCount
		elseif breakpoint.passType == 3 then -- Every
			isHit = breakpoint.hitCount % breakpoint.passCount == 0
		end
	end
	return isHit
end


local function continueStatusProcess(source, line)
	local stackDepth = -1
	if curBreakLine >= 0 then
		stackDepth = getStackDepth() - 2
		if curBreakLine == line and curBreakStackDepth == stackDepth then
			return false
		end
		if stackDepth < curBreakStackDepth or (stackDepth == curBreakStackDepth and line ~= curBreakLine) then
			curBreakLine = -1
		end
	end
	local script = scripts[source]
	if not script then return false end
	local breakpoint = script[line]
	if not breakpoint then return false end
	if isBreakpointBreak(breakpoint) then
		curBreakLine = line
		curBreakStackDepth = stackDepth < 0 and getStackDepth() - 2 or stackDepth
		return true
	end
	return false
end

local function stepOverStatusProcess(source, line)
	local stackDepth = getStackDepth() - 2
	if curBreakLine == line and curBreakStackDepth == stackDepth then return false end
	local script = scripts[source]
	if script then
		local breakpoint = script[line]
		if breakpoint and isBreakpointBreak(breakpoint) then
			curBreakLine = line
			curBreakStackDepth = stackDepth
			return true
		end
	end
	if stackDepth < curBreakStackDepth or (stackDepth == curBreakStackDepth and line ~= curBreakLine) then
		curBreakLine = line
		curBreakStackDepth = stackDepth
		return true
	end
	return false
end

local function stepIntoStatusProcess(source, line)
	local stackDepth = getStackDepth() - 2
	if curBreakLine ~= line or curBreakStackDepth ~= stackDepth then
		local script = scripts[source]
		if script then
			local breakpoint = script[line]
			if breakpoint then
				isBreakpointBreak(breakpoint)
			end
		end
		curBreakLine = line
		curBreakStackDepth = stackDepth
		return true
	end
	return false
end

local function breakStatusProcess(source, line)
	curBreakLine = line
	curBreakStackDepth = getStackDepth() - 2
	return true
end

local function startAttach()
	if isAttaching then return end
	isAttaching = true
	scripts = {}
	scriptMap = {}
	curBreakLine = -1
	curBreakStackDepth = -1
	curProcesser = continueStatusProcess
	clientSocket:send(toMsg(EventKind.AttachDone))
end

local function stopAttach()
	if not isAttaching then return end
	isAttaching = false
	scripts = nil
	scriptMap = nil
	curProcesser = nil
	clientSocket:send(toMsg(EventKind.DetachDone))
	clientSocket:close()
	clientSocket = nil
end

local function loadScript(fileName)
	if not isAttaching or scripts[fileName] then return end
	scripts[fileName] = {index = #scriptMap + 1}
	table.insert(scriptMap, fileName)
	local msg = toMsg(EventKind.LoadScript)
	msg = msg .. toMsg(1)
	msg = msg .. toMsgWithStr(fileName)
	clientSocket:send(msg)
	coroutine.resume(socketCo, "loadScript")
end

local function sendBreakEvent()
	local base = 3
	local lv = base
	local stacks = {}
	while true do
		local info = debug.getinfo(lv, "Snlf")
		if not info then break end
		local stack = {}
		local script = scripts[info.source]
		stack.fileIndex = script and script.index or 0
		stack.line = info.currentline >= 0 and info.currentline or 0
		stack.funcName = info.name or ""
		stack.level = lv - base
		stack.localVariables = {}
		local i,n = 1,1
		while true do
			local name, value = debug.getlocal(lv, i)
			if not name then break end
			if string.sub(name, 1, 1) ~= '(' then
				if n > 50 then
					table.insert(stack.localVariables, "<variable name=\"...\" value=\"\" valueType=\"\"></variable>")
					break
				else
					table.insert(stack.localVariables, toXML(value, name, 1))
				end
				n = n + 1
			end
			i = i + 1
		end
		stack.upvalueVariables = {}
		i = 1
		while info.func do
			local name, value = debug.getupvalue(info.func, i)
			if not name then break end
			if i > 50 then
				table.insert(stack.localVariables, "<variable name=\"...\" value=\"\" valueType=\"\"></variable>")
				break
			else
				table.insert(stack.upvalueVariables, toXML(value, name, 1))
			end
			i = i + 1
		end
		table.insert(stacks,stack)
		lv = lv + 1
	end

	local msg = toMsg(EventKind.Break)
	msg = msg .. toMsg(#stacks)
	for _, stack in ipairs(stacks) do
		msg = msg .. toMsg(stack.fileIndex)
		msg = msg .. toMsgWithStr(stack.funcName)
		msg = msg .. toMsg(stack.line)
		msg = msg .. toMsg(stack.level)
		msg = msg .. toMsg(#stack.localVariables)
		for _, s in ipairs(stack.localVariables) do
			msg = msg .. toMsgWithStr(s)
		end
		msg = msg .. toMsg(#stack.upvalueVariables)
		for _, s in ipairs(stack.upvalueVariables) do
			msg = msg .. toMsgWithStr(s)
		end
	end
	clientSocket:send(msg)
end

local function addBreakpoint(fileIndex, line, isEnabled, condType, condStr, passType, passCount)
	local fileName = scriptMap[fileIndex]
	if not fileName then return end
	local breakpoint = {isEnabled = isEnabled, condType = condType, condStr = condStr,
		passType = passType, passCount = passCount, hitCount = 0, hasValue = false}
	scripts[fileName][line] = breakpoint
	local msg = toMsg(EventKind.AddBreakpointDone)
	msg = msg .. toMsg(fileIndex)
	msg = msg .. toMsg(line)
	clientSocket:send(msg)
end

local function removeBreakpoint(fileIndex, line)
	local fileName = scriptMap[fileIndex]
	if not fileName then return end
	scripts[fileName][line] = nil
end

local function setBreakpointEnabled(fileIndex, line, isEnabled)
	local fileName = scriptMap[fileIndex]
	if not fileName then return end
	local breakpoint = scripts[fileName][line]
	if not breakpoint then return end
	breakpoint.isEnabled = isEnabled
end

local function setBreakpointCondition(fileIndex, line, condType, condStr)
	local fileName = scriptMap[fileIndex]
	if not fileName then return end
	local breakpoint = scripts[fileName][line]
	if not breakpoint then return end
	breakpoint.condType = condType
	breakpoint.condStr = condStr
	breakpoint.hitCount = 0
	breakpoint.hasValue = false
	breakpoint.curValue = nil
end

local function setBreakpointPassCount(fileIndex, line, passType, passCount)
	local fileName = scriptMap[fileIndex]
	if not fileName then return end
	local breakpoint = scripts[fileName][line]
	if not breakpoint then return end
	breakpoint.passType = passType
	breakpoint.passCount = passCount
	breakpoint.hitCount = 0
	breakpoint.hasValue = false
	breakpoint.curValue = nil
end

local function getBreakpointHitCount(fileIndex, line)
	local hitCount
	local fileName = scriptMap[fileIndex]
	if fileName then
		local breakpoint = scripts[fileName][line]
		if breakpoint then
			hitCount = breakpoint.hitCount
		end
	end
	hitCount = hitCount or 0
	local msg = toMsg(EventKind.GetBreakpointHitCountDone)
	msg = msg .. toMsg(fileIndex)
	msg = msg .. toMsg(line)
	msg = msg .. toMsg(hitCount)
	clientSocket:send(msg)
end

local function setBreakpointHitCount(fileIndex, line, hitCount)
	local fileName = scriptMap[fileIndex]
	if not fileName then return end
	local breakpoint = scripts[fileName][line]
	if not breakpoint then return end
	breakpoint.hitCount = hitCount
end

local function deleteAllBreakpoints()
	for n, d in pairs(scripts) do
		scripts[n] = {}
	end
end

local function continueDebug()
	curProcesser = continueStatusProcess
end

local function stepOverDebug()
	curProcesser = stepOverStatusProcess
end

local function stepIntoDebug()
	curProcesser = stepIntoStatusProcess
end

local function breakDebug()
	curProcesser = breakStatusProcess
end

local function acceptConnent()
	local conn = serverSocket:accept()
	if conn then
		clientSocket = conn
		local msg = toMsg(EventKind.InitializeDone)
		clientSocket:send(toMsg(EventKind.InitializeDone))
	end
end

local function evaluateExpression(expression, stackLevel)
	local status, var = evalute(expression, stackLevel + 6)
	local varStr
	if status then
		varStr = toXML(var, expression, 3)
	else
		varStr = string.format("<variable name=\"%s\" value=\"%s\" valueType=\"unknown\"></variable>", toXMLEscape(expression),toXMLEscape(var))
	end
	local msg = toMsg(EventKind.EvaluateDone)
	msg = msg .. toMsg(status and 1 or 0)
	msg = msg .. toMsgWithStr(varStr)
	clientSocket:send(msg)
end

local function receiveMsg(timeout)
	if clientSocket.settimeout then clientSocket:settimeout(timeout) end
	local msg, status = clientSocket:receive(4)
	if status == "closed" then
		stopAttach()
		return
	end
	if msg == nil then return end
	if string.len(msg) < 4 then return end
	if clientSocket.settimeout then clientSocket:settimeout(-1) end
	local msgType = toInt(msg)
	if msgType == CommandKind.Evaluate then
		local expression = clientSocket:receive(toInt(clientSocket:receive(4)))
		local stackLevel = toInt(clientSocket:receive(4))
		evaluateExpression(expression, stackLevel)
	elseif msgType == CommandKind.AddBreakpoint then
		local fileIndex = toInt(clientSocket:receive(4))
		local line = toInt(clientSocket:receive(4))
		local isEnabled = toInt(clientSocket:receive(4))
		local condType = toInt(clientSocket:receive(4))
		local condStr = clientSocket:receive(toInt(clientSocket:receive(4)))
		local passType = toInt(clientSocket:receive(4))
		local passCount = toInt(clientSocket:receive(4))
		addBreakpoint(fileIndex, line, isEnabled > 0, condType,condType,passType,passCount)
	elseif msgType == CommandKind.RemoveBreakpoint then
		local fileIndex = toInt(clientSocket:receive(4))
		local line = toInt(clientSocket:receive(4))
		removeBreakpoint(fileIndex, line)
	elseif msgType == CommandKind.SetBreakpointEnabled then
		local fileIndex = toInt(clientSocket:receive(4))
		local line = toInt(clientSocket:receive(4))
		local isEnabled = toInt(clientSocket:receive(4))
		setBreakpointEnabled(fileIndex,line,isEnabled > 0)
	elseif msgType == CommandKind.SetBreakpointCondition then
		local fileIndex = toInt(clientSocket:receive(4))
		local line = toInt(clientSocket:receive(4))
		local condType = toInt(clientSocket:receive(4))
		local condStr = clientSocket:receive(toInt(clientSocket:receive(4)))
		setBreakpointCondition(fileIndex,line,condType,condStr)
	elseif msgType == CommandKind.SetBreakpointPassCount then
		local fileIndex = toInt(clientSocket:receive(4))
		local line = toInt(clientSocket:receive(4))
		local passType = toInt(clientSocket:receive(4))
		local passCount = toInt(clientSocket:receive(4))
		setBreakpointPassCount(fileIndex,line,passType,passCount)
	elseif msgType == CommandKind.GetBreakpointHitCount then
		local fileIndex = toInt(clientSocket:receive(4))
		local line = toInt(clientSocket:receive(4))
		getBreakpointHitCount(fileIndex,line)
	elseif msgType == CommandKind.SetBreakpointHitCount then
		local fileIndex = toInt(clientSocket:receive(4))
		local line = toInt(clientSocket:receive(4))
		local hitCount = toInt(clientSocket:receive(4))
		setBreakpointHitCount(fileIndex, line, hitCount)
	elseif msgType == CommandKind.DeleteAllBreakpoints then
		deleteAllBreakpoints()
	elseif msgType == CommandKind.StepOver then
		stepOverDebug()
	elseif msgType == CommandKind.StepInto then
		stepIntoDebug()
	elseif msgType == CommandKind.Continue then
		continueDebug()
	elseif msgType == CommandKind.Break then
		breakDebug()
	elseif msgType == CommandKind.Attach then
		local path = clientSocket:receive(toInt(clientSocket:receive(4))) --保留字段，暂无功能
		local errorAlert = toInt(clientSocket:receive(4))-- 远程调试器不实现
		startAttach()
	elseif msgType == CommandKind.Detach then
		stopAttach()
	end
	return msgType
end

local function socketLoop(reType)
	local resumeType = reType
	local lastTime = 0
	while true do
		local curTime = socket.gettime()
		if (resumeType == nil and curTime - lastTime > 0.5)
			or (resumeType ~= nil and curTime - lastTime > 0.02) then
			lastTime = curTime
			if clientSocket then
				local msgType = receiveMsg(resumeType == nil and 0 or 1)
				if resumeType == "loadScript" then
					if msgType == CommandKind.LoadScriptDone then
						resumeType = coroutine.yield()
					end
				else
					resumeType = coroutine.yield()
				end
			else
				acceptConnent()
				resumeType = coroutine.yield()
			end
		elseif resumeType == nil then
			resumeType = coroutine.yield()
		end
	end
end


local function handleBreak()
	while true do
		if clientSocket.settimeout then clientSocket:settimeout(0.01) end
		local msgType = receiveMsg()
		if msgType == CommandKind.Continue or msgType == CommandKind.StepOver
			or msgType == CommandKind.StepInto then
			break
		end
	end
end

local function debug_hook(event, line)
	local st,tt = coroutine.status(socketCo)
	if st == "running" then return end
	if st == "suspended" then
		coroutine.resume(socketCo)
	end
	if isAttaching then
		local info = debug.getinfo(2, "Sl")
		if info.what == "Lua" and info.currentline > 0 and not scripts[info.source] then
			loadScript(info.source)
		end
		if event == "line" then
			if curProcesser(info.source, info.currentline) then
				sendBreakEvent()
				handleBreak()
			end
		elseif event == "call" or event == "return" or event == "tail return" then
			
		end
	end
end

local function hookCoroutine()
	local co, main = coroutine.running()
	if main then co = nil end
	if co then
		debug.sethook(co, debug_hook, HOOKMASK)
	else
		debug.sethook(debug_hook, HOOKMASK)
	end
end

local cocreate = coroutine.create
coroutine.create = function(f, ...)
	return cocreate(function(...)
		if isAttaching then
			hookCoroutine()
		end
		return f(...)
	end, ...)
end

local oriPrint = print
print = function(...)
	if isAttaching then
		local p = {...}
		local log = ""
		local count = #p
		for i = 1, count do
			local s, r = pcall(tostring, p[i])
			log = log .. r
			if i < count then
				log = log .. ','
			end
		end
		local msg = toMsg(EventKind.Print)
		msg = msg .. toMsgWithStr(log)
		clientSocket:send(msg)
	end
	oriPrint(...)
end

local function start()
	serverSocket = assert(socket.bind("*", DebugPort))
	if serverSocket.settimeout then serverSocket:settimeout(DebugConnentTimeout) end
	local conn = serverSocket:accept()
	if serverSocket.settimeout then serverSocket:settimeout(0) end
	if conn then
		if conn.settimeout then conn:settimeout(0) end
		clientSocket = conn
		clientSocket:send(toMsg(EventKind.InitializeDone))
	end
	socketCo = cocreate(socketLoop)
	debug.sethook(debug_hook, HOOKMASK)
end

start()