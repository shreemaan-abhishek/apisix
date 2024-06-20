return {
	table_count = {
		lua_modules = { "t.table-count-example" }, -- change it
		interval = 5,
		depth = 10, -- when it is not passed, default depth will be 1
		-- optional, default is all APISIX processes
		scopes = {"worker", "privileged agent"}
	}
}
