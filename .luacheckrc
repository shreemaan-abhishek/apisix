files["apisix/plugins/trace.lua"] = {
  globals = {
    "package",
    "ngx"
  }
}
files["apisix/core/sandbox/base.lua"] = {
  read_globals = {
    "load",
    "_ENV",
    "_G",
  }
}
files["apisix/plugin.lua"] = {
  read_globals = {
    "load",
  }
}
files["apisix/plugins/exit-transformer.lua"] = {
  read_globals = {
    "load",
  }
}
