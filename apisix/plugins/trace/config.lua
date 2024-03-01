return {
  rate = 1, -- allow only 1 request per 100 requests
  hosts = {}, -- only the requests carrying these host headers will be traced
  paths = {}, -- only these request_uris will be traced
}
