AddCSLuaFile("init.lua")

/******************************************************************************\
  Expression 2 for Garry's Mod
  Andreas "Syranide" Svensson, me@syranide.com
\******************************************************************************/

// ADD FUNCTIONS FOR COLOR CONVERSION!
// ADD CONSOLE SUPPORT

/*
n = numeric
v = vector
s = string
t = table
e = entity
x = non-basic extensions prefix
*/

wire_expression2_delta = 0.0000001000000
delta = wire_expression2_delta

/******************************************************************************/
/******************************************************************************/
/******************************************************************************/
/******************************************************************************/
/******************************************************************************/
/******************************************************************************/

/******************************************************************************/
-- functions to type-check function return values.

local wire_expression2_debug = CreateConVar("wire_expression2_debug", 0, 0)

cvars.AddChangeCallback("wire_expression2_debug", function(CVar, PreviousValue, NewValue)
	if (PreviousValue) == NewValue then return end
	wire_expression2_reload()
end)

-- Removes a typecheck from a function identified by the given signature.
local function removecheck(signature)
	local entry = wire_expression2_funcs[signature]
	local oldfunc,signature, rets, func,cost = entry.oldfunc,unpack(entry)

	if not oldfunc then return end
	func = oldfunc
	oldfunc = nil

	entry[3] = func
	entry.oldfunc = oldfunc
end

-- TODO: combine with makecheck
local function namefunc(func, name)
	name = "e2_"..name:gsub("[^A-Za-z_0-9]","_")

	wire_expression2_namefunc = func
	RunString(([[
		local %s = wire_expression2_namefunc
		function wire_expression2_namefunc(...)
			local ret = %s(...)
			return ret
		end
	]]):format(name, name))
	local ret = wire_expression2_namefunc
	wire_expression2_namefunc = nil
	return ret
end

-- Installs a typecheck in a function identified by the given signature.
local function makecheck(signature)
	local name = signature:match("^([^(]*)")
	local entry = wire_expression2_funcs[signature]
	local oldfunc,signature, rets, func,cost = entry.oldfunc,unpack(entry)

	if oldfunc then return end
	oldfunc = namefunc(func, name)

	function func(...)
		local retval = oldfunc(...)

		local checker = wire_expression_types2[rets][5]
		if not checker then return retval end

		local ok, msg = pcall(checker, retval)
		if ok then return retval end
		debug.Trace()
		local full_signature = E2Lib.generate_signature(signature, rets)
		error(string.format("Type check for function %q failed: %s\n", full_signature, msg),0)

		return retval
	end

	entry[3] = func
	entry.oldfunc = oldfunc
end

/******************************************************************************/

function wire_expression2_reset_extensions()
	wire_expression_callbacks = {
		construct = {},
		destruct = {},
		preexecute = {},
		postexecute = {},
	}

	wire_expression_types = {}
	wire_expression_types2 = {
		[""] = {
			[5] = function() if checker ~= nil then error("Return value of void function is not nil.",0) end end
		}
	}
	wire_expression2_funcs = {}
	wire_expression2_funclist = {}
	wire_expression2_constants = {}
end

-- additional args: <input serializer>, <output serializer>, <type checker>
function registerType(name, id, def, ...)
	wire_expression_types[string.upper(name)] = {id, def, ...}
	wire_expression_types2[id] = {string.upper(name), def, ...}
	if not WireLib.DT[string.upper(name)] then
		WireLib.DT[string.upper(name)] = { Zero = def }
	end
end

function wire_expression2_CallHook(hookname, ...)
	if not wire_expression_callbacks[hookname] then return end
	local ret_array = {}
	local errors = {}
	local ok, ret
	for i,callback in ipairs(wire_expression_callbacks[hookname]) do
		e2_install_hook_fix()
		ok, ret = pcall(callback, ...)
		e2_remove_hook_fix()
		if not ok then
			if ret == "cancelhook" then break end
			table.insert(errors, "\n"..e2_processerror(ret))
			ret_array = nil
		else
			if ret_array then table.insert(ret_array, ret or false) end
		end
	end
	if not ret_array then error("Error(s) occured while executing '"..hookname.."' hook:"..table.concat(errors),0) end
	return ret_array
end

function registerCallback(event, callback)
	if not wire_expression_callbacks[event] then wire_expression_callbacks[event] = {} end
	table.insert(wire_expression_callbacks[event], callback)
end

local tempcost

function __e2setcost(cost)
	tempcost = cost
end
function __e2getcost()
	return tempcost
end

function registerOperator(name, pars, rets, func, cost, argnames)
	local signature = "op:" .. name .. "(" .. pars .. ")"

	wire_expression2_funcs[signature] = { signature, rets, func, cost or tempcost, argnames=argnames }
	if wire_expression2_debug:GetBool() then makecheck(signature) end
end

function registerFunction(name, pars, rets, func, cost, argnames)
	local signature = name .. "(" .. pars .. ")"

	wire_expression2_funcs[signature] = { signature, rets, func, cost or tempcost, argnames=argnames }
	wire_expression2_funclist[name] = true
	if wire_expression2_debug:GetBool() then makecheck(signature) end
end

function E2Lib.registerConstant(name, value, literal)
	if name:sub(1,1) ~= "_" then name = "_"..name end
	if not value and not literal then value = _G[name] end

	wire_expression2_constants[name] = value
end

/******************************************************************************/

if not datastream then require( "datastream" ) end

if SERVER then

	e2_processerror = nil
	local clientside_files = {}

	function AddCSE2File(filename)
		AddCSLuaFile(filename)
		clientside_files[filename] = true
	end
	include("extloader.lua")

	-- -- Transfer E2 function info to the client for validation and syntax highlighting purposes -- --

	function _R.CRecipientFilter.IsValid() return true end -- workaround for this bug: http://www.facepunch.com/showpost.php?p=15117600 - thanks Lexi

	do
		if (!glon) then require("glon") end -- Doubt this will be necessary, but still

		local functiondata,functiondata2
		local functiondata_buffer, functiondata2_buffer = {}, {}

		-- prepares a table with information (no, a glon string! - edit by Divran) about E2 types and functions
		function wire_expression2_prepare_functiondata()
			functiondata = { {}, {}, clientside_files, wire_expression2_constants }
			functiondata2 = {}
			for typename,v in pairs(wire_expression_types) do
				functiondata[1][typename] = v[1] -- typeid
			end

			for signature,v in pairs(wire_expression2_funcs) do
				functiondata[2][signature] = v[2] -- ret
				functiondata2[signature] = { v[4], v.argnames } -- cost, argnames
			end

			-- Add functiondata to buffer
			local temp = glon.encode( functiondata )
			local count = 1
			local char = temp:sub(1,1)
			local temp2 = ""
			while( char != "" ) do
				temp2 = temp2 .. char
				if (count % 245 == 0) then
					functiondata_buffer[#functiondata_buffer+1] = temp2
					temp2 = ""
				end
				count = count + 1
				char = temp:sub(count,count)
			end
			if (temp2 != "") then
				functiondata_buffer[#functiondata_buffer+1] = temp2
			end

			-- Add functiondata2 to buffer
			local temp = glon.encode( functiondata2 )
			local count = 1
			local char = temp:sub(1,1)
			local temp2 = ""
			while( char != "" ) do
				temp2 = temp2 .. char
				if (count % 245 == 0) then
					functiondata2_buffer[#functiondata2_buffer+1] = temp2
					temp2 = ""
				end
				count = count + 1
				char = temp:sub(count,count)
			end
			if (temp2 != "") then
				functiondata2_buffer[#functiondata2_buffer+1] = temp2
			end
		end

		wire_expression2_prepare_functiondata()

		local targets = {}
		local function sendData( target )
			if (type(target) == "table") then
				for k,v in pairs( target ) do
					if (type(v) == "Player") then
						sendData( v )
					end
				end
				return
			end
			if (target and type(target) == "Player" and target:IsValid()) then
				targets[target] = { 1, 0 }
			end
		end

		hook.Add("Think","wire_expression2_sendfunctions_think",function()
			for k,v in pairs( targets ) do
				if (!k:IsValid() or !k:IsPlayer() or v[1] == 3) then
					targets[k] = nil
				elseif (v[1] == 1) then -- functiondata
					v[2] = v[2] + 1
					umsg.Start("e2sd",k) umsg.String( functiondata_buffer[v[2]] ) umsg.End()
					if (v[2] == #functiondata_buffer) then
						umsg.Start("e2se",k) umsg.Bool(false) umsg.End()
						v[1] = 2
						v[2] = 0
					end
				elseif (v[1] == 2) then -- functiondata2
					v[2] = v[2] + 1
					umsg.Start("e2sd",k) umsg.String( functiondata2_buffer[v[2]] ) umsg.End()
					if (v[2] == #functiondata2_buffer) then
						umsg.Start("e2se",k) umsg.Bool(true) umsg.End()
						v[1] = 3
						v[2] = 0
					end
				end
			end
		end)

		local antispam = {}
		function wire_expression2_sendfunctions(ply,isconcmd)
			if (isconcmd) then
				if (!antispam[ply]) then antispam[ply] = 0 end
				if (antispam[ply] > CurTime()) then
					ply:PrintMessage(HUD_PRINTCONSOLE,"This command has a 60 second anti spam protection. Try again in " .. math.Round(antispam[ply] - CurTime()) .. " seconds.")
					return
				end
				antispam[ply] = CurTime() + 60
				sendData( ply )
			else
				timer.Simple( 5, function(ply)
					sendData( ply )
				end, ply)
			end
		end

		-- add a console command the user can use to re-request the function info, in case of errors or updates
		concommand.Add("wire_expression2_sendfunctions", wire_expression2_sendfunctions)

		-- send function info once the player first spawns (TODO: find an even earlier hook)
		hook.Add("PlayerInitialSpawn", "wire_expression2_sendfunctions", wire_expression2_sendfunctions)
	end

elseif CLIENT then

	e2_function_data_received = nil
	-- -- Receive E2 function info from the server for validation and syntax highlighting purposes -- --

	wire_expression2_reset_extensions()

	local function insertData( functiondata )
		wire_expression2_reset_extensions()

		-- types
		for typename,typeid in pairs(functiondata[1]) do
			wire_expression_types[typename] = { typeid }
			wire_expression_types2[typeid] = { typename }
		end

		-- functions
		for signature,ret in pairs(functiondata[2]) do
			local fname = signature:match("^([^(:]+)%(")
			if fname then wire_expression2_funclist[fname] = true end
			wire_expression2_funcs[signature] = { signature, ret, false }
		end

		-- includes
		for filename,_ in pairs(functiondata[3]) do
			include("entities/gmod_wire_expression2/core/"..filename)
		end

		-- constants
		wire_expression2_constants = functiondata[4]

		e2_function_data_received = true

		if wire_expression2_editor then wire_expression2_editor:Validate(false) end
	end
	local function insertData2( functiondata2 )
		for signature,v in pairs(functiondata2) do
			local entry = wire_expression2_funcs[signature]
			if entry then
				entry[4] = v[1] -- cost
				entry.argnames = v[2] -- argnames
			end
		end
	end

	local already_tried
	local buffer = ""
	usermessage.Hook("e2sd",function( um )
		local str = um:ReadString()
		buffer = buffer .. str
	end)
	usermessage.Hook("e2se",function( um )
		local OK, data = pcall( glon.decode, buffer )
		if (!OK) then
			if (already_tried) then
				LocalPlayer():ChatPrint("[E2] Failed to receive functions data. Error message was:\n" .. data)
			else
				already_tried = true
				RunConsoleCommand("wire_expression2_sendfunctions")
				LocalPlayer():ChatPrint("[E2] Failed to receive functions data. Trying again. Error message was:\n" .. data)
			end
		else
			local what = um:ReadBool()
			if (!what) then
				insertData( data )
			else
				insertData2( data )
			end
		end
		buffer = ""
	end)

	if CanRunConsoleCommand() then
		RunConsoleCommand("wire_expression2_sendfunctions")
	end

end

include("e2doc.lua")
