-- Units
kB = 1024
MB = 1024*kB
GB = 1024*MB
-- Time
sec = 1000
second = sec
minute = 60 * sec
min = minute
hour = 60 * minute
day = 24 * hour

-- Logging
function panic(fmt, ...)
        error(string.format('error: '..fmt, ...))
end
function warn(fmt, ...)
        io.stderr:write(string.format(fmt..'\n', ...))
end
function log(fmt, ...)
        print(string.format(fmt, ...))
end

-- Resolver bindings
kres = require('kres')
trust_anchors = require('trust_anchors')
if rawget(kres, 'str2dname') ~= nil then
	todname = kres.str2dname
end

-- Compat. wrapper for query flags.
worker.resolve = function (p1, p2, p3, options, p5)
	options = kres.mk_qflags(options)
	return worker.resolve_unwrapped (p1, p2, p3, options, p5)
end
resolve = worker.resolve

-- Shorthand for aggregated per-worker information
worker.info = function ()
	local t = worker.stats()
	t.pid = worker.pid
	return t
end

-- Resolver mode of operation
local current_mode = 'normal'
local mode_table = { normal=0, strict=1, permissive=2 }
function mode(m)
	if not m then return current_mode end
	if not mode_table[m] then error('unsupported mode: '..m) end
	-- Update current operation mode
	current_mode = m
	option('STRICT', current_mode == 'strict')
	option('PERMISSIVE', current_mode == 'permissive')
	return true
end

-- Trivial option alias
function reorder_RR(val)
	return option('REORDER_RR', val)
end

-- Get/set resolver options via name (string)
function option(name, val)
	local flags = kres.context().options;
	-- Note: no way to test existence of flags[name] but we want error anyway.
	name = string.upper(name) -- convenience
	if val ~= nil then
		if (val ~= true) and (val ~= false) then
			panic('invalid option value: ' .. tostring(val))
		end
		flags[name] = val;
	end
	return flags[name];
end

-- Function aliases
-- `env.VAR returns os.getenv(VAR)`
env = {}
setmetatable(env, {
	__index = function (_, k) return os.getenv(k) end
})

-- Quick access to interfaces
-- `net.<iface>` => `net.interfaces()[iface]`
-- `net = {addr1, ..}` => `net.listen(name, addr1)`
-- `net.ipv{4,6} = {true, false}` => enable/disable IPv{4,6}
setmetatable(net, {
	__index = function (t, k)
		local v = rawget(t, k)
		if v then return v
		elseif k == 'ipv6' then return not option('NO_IPV6')
		elseif k == 'ipv4' then return not option('NO_IPV4')
		else return net.interfaces()[k]
		end
	end,
	__newindex = function (t,k,v)
		if     k == 'ipv6' then return option('NO_IPV6', not v)
		elseif k == 'ipv4' then return option('NO_IPV4', not v)
		else
			local iname = rawget(net.interfaces(), v)
			if iname then t.listen(iname)
			else t.listen(v)
			end
		end
	end
})

-- Syntactic sugar for module loading
-- `modules.<name> = <config>`
setmetatable(modules, {
	__newindex = function (_, k, v)
		if type(k) == 'number' then
			k, v = v, nil
		end
		if not rawget(_G, k) then
			modules.load(k)
			k = string.match(k, '[%w_]+')
			local mod = _G[k]
			local config = mod and rawget(mod, 'config')
			if mod ~= nil and config ~= nil then
				if k ~= v then config(v)
				else           config()
				end
			end
		end
	end
})

-- Syntactic sugar for cache
-- `cache[x] -> cache.get(x)`
-- `cache.{size|storage} = value`
setmetatable(cache, {
	__index = function (t, k)
		local res = rawget(t, k)
		if res and not rawget(t, 'current_size') then return res end
		-- Beware: t.get returns empty table on failure to find.
		-- That would be confusing here (breaking kresc), so return nil instead.
		res = t.get(k)
		if res and next(res) ~= nil then return res else return nil end
	end,
	__newindex = function (t,k,v)
		-- Defaults
		local storage = rawget(t, 'current_storage')
		if not storage then storage = 'lmdb://' end
		local size = rawget(t, 'current_size')
		if not size then size = 10*MB end
		-- Declarative interface for cache
		if     k == 'size'    then t.open(v, storage)
		elseif k == 'storage' then t.open(size, v) end
	end
})

-- Register module in Lua environment
function modules_register(module)
	-- Syntactic sugar for get() and set() properties
	setmetatable(module, {
		__index = function (t, k)
			local  v = rawget(t, k)
			if     v     then return v
			elseif rawget(t, 'get') then return t.get(k)
			end
		end,
		__newindex = function (t, k, v)
			local  old_v = rawget(t, k)
			if not old_v and rawget(t, 'set') then
				t.set(k..' '..v)
			end
		end
	})
end

-- Make sandboxed environment
local function make_sandbox(defined)
	local __protected = { modules = true, cache = true, net = true, trust_anchors = true }

	-- Compute and export the list of top-level names (hidden otherwise)
	local nl = ""
	for n in pairs(defined) do
		nl = nl .. n .. "\n"
	end

	return setmetatable({ __orig_name_list = nl }, {
		__index = defined,
		__newindex = function (_, k, v)
			if __protected[k] then
				for k2,v2 in pairs(v) do
					defined[k][k2] = v2
				end
			else
				defined[k] = v
			end
		end
	})
end

-- Compatibility sandbox
if setfenv then -- Lua 5.1 and less
	_G = make_sandbox(getfenv(0))
	setfenv(0, _G)
else -- Lua 5.2+
	_SANDBOX = make_sandbox(_ENV)
end

-- Load embedded modules
modules.load('ta_signal_query')

-- Interactive command evaluation
function eval_cmd(line, raw)
	-- Compatibility sandbox code loading
	local function load_code(code)
	    if getfenv then -- Lua 5.1
	        return loadstring(code)
	    else            -- Lua 5.2+
	        return load(code, nil, 't', _ENV)
	    end
	end
	local err, chunk
	chunk, err = load_code(raw and 'return '..line or 'return table_print('..line..')')
	if err then
		chunk, err = load_code(line)
	end
	if not err then
		return chunk()
	else
		error(err)
	end
end

-- Pretty printing
function table_print (tt, indent, done)
	done = done or {}
	indent = indent or 0
	local result = ""
	-- Convert to printable string (escape unprintable)
	local function printable(value)
		value = tostring(value)
		local bytes = {}
		for i = 1, #value do
			local c = string.byte(value, i)
			if c >= 0x20 and c < 0x7f then table.insert(bytes, string.char(c))
			else                           table.insert(bytes, '\\'..tostring(c))
			end
			if i > 50 then table.insert(bytes, '...') break end
		end
		return table.concat(bytes)
	end
	if type(tt) == "table" then
		for key, value in pairs (tt) do
			result = result .. string.rep (" ", indent)
			if type (value) == "table" and not done [value] then
				done [value] = true
				result = result .. string.format("[%s] => {\n", printable (key))
				result = result .. table_print (value, indent + 4, done)
				result = result .. string.rep (" ", indent)
				result = result .. "}\n"
			else
				result = result .. string.format("[%s] => %s\n",
				         tostring (key), printable(value))
			end
		end
	else
		result = result .. tostring(tt) .. "\n"
	end
	return result
end
