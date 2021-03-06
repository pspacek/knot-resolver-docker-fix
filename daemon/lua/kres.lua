-- LuaJIT ffi bindings for libkres, a DNS resolver library.
-- @note Since it's statically compiled, it expects to find the symbols in the C namespace.

local kres -- the module

local ffi = require('ffi')
local bit = require('bit')
local bor = bit.bor
local band = bit.band
local C = ffi.C
local knot = ffi.load(libknot_SONAME)

-- Various declarations that are very stable.
ffi.cdef[[
/*
 * Data structures
 */

/* stdlib */
typedef long time_t;
struct timeval {
	time_t tv_sec;
	time_t tv_usec;
};
struct sockaddr {
    uint16_t sa_family;
    uint8_t _stub[]; /* Do not touch */
};

/*
 * libc APIs
 */
void * malloc(size_t size);
void free(void *ptr);
int inet_pton(int af, const char *src, void *dst);
]]

require('kres-gen')

-- Constant tables
local const_class = {
	IN         =   1,
	CH         =   3,
	NONE       = 254,
	ANY        = 255,
}
local const_type = {
	A          =   1,
	NS         =   2,
	CNAME      =   5,
	SOA        =   6,
	PTR        =  12,
	HINFO      =  13,
	MINFO      =  14,
	MX         =  15,
	TXT        =  16,
	RP         =  17,
	AFSDB      =  18,
	RT         =  21,
	SIG        =  24,
	KEY        =  25,
	AAAA       =  28,
	LOC        =  29,
	SRV        =  33,
	NAPTR      =  35,
	KX         =  36,
	CERT       =  37,
	DNAME      =  39,
	OPT        =  41,
	APL        =  42,
	DS         =  43,
	SSHFP      =  44,
	IPSECKEY   =  45,
	RRSIG      =  46,
	NSEC       =  47,
	DNSKEY     =  48,
	DHCID      =  49,
	NSEC3      =  50,
	NSEC3PARAM =  51,
	TLSA       =  52,
	CDS        =  59,
	CDNSKEY    =  60,
	SPF        =  99,
	NID        = 104,
	L32        = 105,
	L64        = 106,
	LP         = 107,
	EUI48      = 108,
	EUI64      = 109,
	TKEY       = 249,
	TSIG       = 250,
	IXFR       = 251,
	AXFR       = 252,
	ANY        = 255,
}
local const_section = {
	ANSWER     = 0,
	AUTHORITY  = 1,
	ADDITIONAL = 2,
}
local const_rcode = {
	NOERROR    =  0,
	FORMERR    =  1,
	SERVFAIL   =  2,
	NXDOMAIN   =  3,
	NOTIMPL    =  4,
	REFUSED    =  5,
	YXDOMAIN   =  6,
	YXRRSET    =  7,
	NXRRSET    =  8,
	NOTAUTH    =  9,
	NOTZONE    = 10,
	BADVERS    = 16,
	BADCOOKIE  = 23,
}

-- Metatype for RR types to allow anonymous types
setmetatable(const_type, {
	__index = function (t, k)
		local v = rawget(t, k)
		if v then return v end
		-- Allow TYPE%d notation
		if string.find(k, 'TYPE', 1, true) then
			return tonumber(k:sub(5))
		end
		-- Unknown type
		return
	end
})

-- Metatype for sockaddr
local addr_buf = ffi.new('char[16]')
local sockaddr_t = ffi.typeof('struct sockaddr')
ffi.metatype( sockaddr_t, {
	__index = {
		len = function(sa) return C.kr_inaddr_len(sa) end,
		ip = function (sa) return C.kr_inaddr(sa) end,
		family = function (sa) return C.kr_inaddr_family(sa) end,
	}
})

-- Metatype for RR set.  Beware, the indexing is 0-based (rdata, get, tostring).
local rrset_buflen = (64 + 1) * 1024
local rrset_buf = ffi.new('char[?]', rrset_buflen)
local knot_rrset_t = ffi.typeof('knot_rrset_t')
ffi.metatype( knot_rrset_t, {
	-- beware: `owner` and `rdata` are typed as a plain lua strings
	--         and not the real types they represent.
	__index = {
		owner = function(rr) return ffi.string(rr._owner, knot.knot_dname_size(rr._owner)) end,
		ttl = function(rr) return tonumber(knot.knot_rrset_ttl(rr)) end,
		rdata = function(rr, i)
			local rdata = knot.knot_rdataset_at(rr.rrs, i)
			return ffi.string(knot.knot_rdata_data(rdata), knot.knot_rdata_rdlen(rdata))
		end,
		get = function(rr, i)
			return {owner = rr:owner(),
			        ttl = rr:ttl(),
			        class = tonumber(rr.rclass),
			        type = tonumber(rr.type),
			        rdata = rr:rdata(i)}
		end,
		tostring = function(rr, i)
			assert(ffi.istype(knot_rrset_t, rr))
			if rr.rrs.rr_count > 0 then
				local ret
				if i ~= nil then
					ret = knot.knot_rrset_txt_dump_data(rr, i, rrset_buf, rrset_buflen, knot.KNOT_DUMP_STYLE_DEFAULT)
				else
					ret = -1
				end
				return ret >= 0 and ffi.string(rrset_buf)
			end
		end,

		-- Dump the rrset in presentation format (dig-like).
		txt_dump = function(rr, style)
			local bufsize = 1024
			local dump = ffi.new('char *[1]', C.malloc(bufsize))
				-- ^ one pointer to a string
			local size = ffi.new('size_t[1]', { bufsize }) -- one size_t = bufsize

			local ret = knot.knot_rrset_txt_dump(rr, dump, size,
							style or knot.KNOT_DUMP_STYLE_DEFAULT)
			local result = nil
			if ret >= 0 then
				result = ffi.string(dump[0], ret)
			end
			C.free(dump[0])
			return result
		end,
	},
})

-- Metatype for packet
local knot_pkt_t = ffi.typeof('knot_pkt_t')
ffi.metatype( knot_pkt_t, {
	__index = {
		qname = function(pkt)
			local qname = knot.knot_pkt_qname(pkt)
			return ffi.string(qname, knot.knot_dname_size(qname))
		end,
		qclass = function(pkt) return knot.knot_pkt_qclass(pkt) end,
		qtype  = function(pkt) return knot.knot_pkt_qtype(pkt) end,
		rcode = function (pkt, val)
			pkt.wire[3] = (val) and bor(band(pkt.wire[3], 0xf0), val) or pkt.wire[3]
			return band(pkt.wire[3], 0x0f)
		end,
		tc = function (pkt, val)
			pkt.wire[2] = bor(pkt.wire[2], (val) and 0x02 or 0x00)
			return band(pkt.wire[2], 0x02)
		end,
		rrsets = function (pkt, section_id)
			local records = {}
			local section = knot.knot_pkt_section(pkt, section_id)
			for i = 1, section.count do
				local rrset = knot.knot_pkt_rr(section, i - 1)
				table.insert(records, rrset)
			end
			return records
		end,
		section = function (pkt, section_id)
			local records = {}
			local section = knot.knot_pkt_section(pkt, section_id)
			for i = 1, section.count do
				local rrset = knot.knot_pkt_rr(section, i - 1)
				for k = 1, rrset.rrs.rr_count do
					table.insert(records, rrset:get(k - 1))
				end
			end
			return records
		end,
		begin = function (pkt, section) return knot.knot_pkt_begin(pkt, section) end,
		put = function (pkt, owner, ttl, rclass, rtype, rdata)
			return C.kr_pkt_put(pkt, owner, ttl, rclass, rtype, rdata, #rdata)
		end,
		clear = function (pkt) return C.kr_pkt_recycle(pkt) end,
		question = function(pkt, qname, qclass, qtype)
			return C.knot_pkt_put_question(pkt, qname, qclass, qtype)
		end,
	},
})
-- Metatype for query
local kr_query_t = ffi.typeof('struct kr_query')
ffi.metatype( kr_query_t, {
	__index = {
		name = function(qry) return ffi.string(qry.sname, knot.knot_dname_size(qry.sname)) end,
	},
})
-- Metatype for request
local kr_request_t = ffi.typeof('struct kr_request')
ffi.metatype( kr_request_t, {
	__index = {
		current = function(req)
			assert(req)
			if req.current_query == nil then return nil end
			return req.current_query
		end,
		resolved = function(req)
			assert(req)
			local qry = C.kr_rplan_resolved(C.kr_resolve_plan(req))
			if qry == nil then return nil end
			return qry

		end,
		push = function(req, qname, qtype, qclass, flags, parent)
			assert(req)
			flags = kres.mk_qflags(flags) -- compatibility
			local rplan = C.kr_resolve_plan(req)
			local qry = C.kr_rplan_push(rplan, parent, qname, qclass, qtype)
			if qry ~= nil and flags ~= nil then
				C.kr_qflags_set(qry.flags, flags)
			end
			return qry
		end,
		pop = function(req, qry)
			assert(req)
			return C.kr_rplan_pop(C.kr_resolve_plan(req), qry)
		end,
	},
})

-- Pretty print for domain name
local function dname2str(dname)
	return ffi.string(ffi.gc(C.knot_dname_to_str(nil, dname, 0), C.free))
end

-- Pretty-print a single RR (which is a table with .owner .ttl .type .rdata)
-- Extension: append .comment if exists.
local function rr2str(rr, style)
	-- Construct a single-RR temporary set while minimizing copying.
	local rrs = knot_rrset_t()
	knot.knot_rrset_init_empty(rrs)
	rrs._owner = ffi.cast('knot_dname_t *', rr.owner) -- explicit cast needed here
	rrs.type = rr.type
	rrs.rclass = kres.class.IN
	knot.knot_rrset_add_rdata(rrs, rr.rdata, #rr.rdata, rr.ttl, nil)

	local ret = rrs:txt_dump(style)
	C.free(rrs.rrs.data)

	-- Trim the newline and append comment (optionally).
	if ret then
		if ret:byte(-1) == string.byte('\n', -1) then
			ret = ret:sub(1, -2)
		end
		if rr.comment then
			ret = ret .. ' ;' .. rr.comment
		end
	end
	return ret
end

-- Module API
kres = {
	-- Constants
	class = const_class,
	type = const_type,
	section = const_section,
	rcode = const_rcode,

	-- Create a struct kr_qflags from a single flag name or a list of names.
	mk_qflags = function (names)
		local kr_qflags = ffi.typeof('struct kr_qflags')
		if names == 0 or names == nil then -- compatibility: nil is common in lua
			names = {}
		elseif type(names) == 'string' then
			names = {names}
		elseif ffi.istype(kr_qflags, names) then
			return names
		end

		local fs = ffi.new(kr_qflags)
		for _, name in pairs(names) do
			fs[name] = true
		end
		return fs
	end,

	CONSUME = 1, PRODUCE = 2, DONE = 4, FAIL = 8, YIELD = 16,
	-- Metatypes.  Beware that any pointer will be cast silently...
	pkt_t = function (udata) return ffi.cast('knot_pkt_t *', udata) end,
	request_t = function (udata) return ffi.cast('struct kr_request *', udata) end,
	-- Global API functions
	str2dname = function(name)
		local dname = ffi.gc(C.knot_dname_from_str(nil, name, 0), C.free)
		return ffi.string(dname, knot.knot_dname_size(dname))
	end,
	dname2str = dname2str,
	rr2str = rr2str,
	str2ip = function (ip)
		local family = C.kr_straddr_family(ip)
		local ret = C.inet_pton(family, ip, addr_buf)
		if ret ~= 1 then return nil end
		return ffi.string(addr_buf, C.kr_family_len(family))
	end,
	context = function () return ffi.cast('struct kr_context *', __engine) end,
}

return kres
