-- Copyright 2008 Steven Barth <steven@midlink.org>
-- Copyright 2008 Jo-Philipp Wich <jow@openwrt.org>
-- Licensed to the public under the Apache License 2.0.

module("luci.controller.upnp", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/upnpd") then
		return
	end

	local page

	__RUTX_PLATFORM_START__
	page = entry({"admin", "services", "upnp"}, cbi("upnp/upnp"), _("UPNP"), 210)
	page.dependent = true

	entry({"admin", "services", "upnp", "status"}, call("act_status")).leaf = true
	entry({"admin", "services", "upnp", "delete"}, call("act_delete")).leaf = true
	entry({"admin", "services", "upnp", "rule"}, call("act_rule")).leaf = true
	__RUTX_PLATFORM_END__
end

function act_status()
	local ipt = io.popen("iptables --line-numbers -t nat -xnvL MINIUPNPD 2>/dev/null")
	if ipt then
		local fwd = { }
		while true do
			local ln = ipt:read("*l")
			if not ln then
				break
			elseif ln:match("^%d+") then
				local num, proto, extport, intaddr, intport =
					ln:match("^(%d+).-([a-z]+).-dpt:(%d+) to:(%S-):(%d+)")

				if num and proto and extport and intaddr and intport then
					num     = tonumber(num)
					extport = tonumber(extport)
					intport = tonumber(intport)

					fwd[#fwd+1] = {
						num     = num,
						proto   = proto:upper(),
						extport = extport,
						intaddr = intaddr,
						intport = intport
					}
				end
			end
		end

		ipt:close()

		luci.http.prepare_content("application/json")
		luci.http.write_json(fwd)
	end
end

function act_delete(num)
	local idx = tonumber(num)
	local uci = luci.model.uci.cursor()

	if idx and idx > 0 then
		luci.sys.call("iptables -t filter -D MINIUPNPD %d 2>/dev/null" % idx)
		luci.sys.call("iptables -t nat -D MINIUPNPD %d 2>/dev/null" % idx)

		local lease_file = uci:get("upnpd", "config", "upnp_lease_file")
		if lease_file and nixio.fs.access(lease_file) then
			luci.sys.call("sed -i -e '%dd' %q" %{ idx, lease_file })
		end

		luci.http.status(200, "OK")
		return
	end

	luci.http.status(400, "Bad request")
end


function act_rule(id)
	local idx = tonumber(id)
	local sys = require "luci.sys"
	local sqlite = require "lsqlite3"
	local dbPath = "/log/"
	local dbName = "upnp-errors.db"
	local dbFullPath = dbPath .. "" ..dbName
	local messageList = {}

	-- get record from db
	local db = sqlite.open(dbFullPath)
	local query = "SELECT * FROM errors WHERE id = " .. idx
	local stmt = db:prepare(query)
	if stmt then
	    for row in db:nrows(query) do
	        messageList[#messageList+1] = row
	    end
	end

	-- append rule to list
	local uci = luci.model.uci.cursor()
	local name = uci:add("upnpd", "perm_rule")

	uci:set("upnpd", name, "comment", "opened_port_" .. messageList[1].id)
	uci:set("upnpd", name, "int_addr", messageList[1].internal_ip)
	uci:set("upnpd", name, "int_ports", messageList[1].internal_port)
	uci:set("upnpd", name, "ext_ports", messageList[1].external_port)
	uci:set("upnpd", name, "action", "allow")
	uci:reorder("upnpd", name, 0)
	uci:commit("upnpd")

	local deleteQuery = "DELETE FROM errors WHERE id = " .. idx
	db:exec(deleteQuery)

	db:close()

	luci.http.status(200, "OK")
	return

end
