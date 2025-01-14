local multipart = require "multipart"
local cjson = require "cjson"
local pl_template = require "pl.template"
local pl_tablex = require "pl.tablex"

local table_insert = table.insert
local get_uri_args = kong.request.get_query
local set_uri_args = kong.service.request.set_query
local clear_header = kong.service.request.clear_header
local get_header = kong.request.get_header
local set_header = kong.service.request.set_header
local get_headers = kong.request.get_headers
local set_headers = kong.service.request.set_headers
local set_method = kong.service.request.set_method
local get_method = kong.request.get_method
local get_raw_body = kong.request.get_raw_body
local set_raw_body = kong.service.request.set_raw_body
local encode_args = ngx.encode_args
local ngx_decode_args = ngx.decode_args
local jwt_decoder = require "kong.plugins.kong-plugin-custom-request-transformer.jwt_parser"
local type = type
local str_find = string.find
local pcall = pcall
local pairs = pairs
local error = error
local rawset = rawset
local pl_copy_table = pl_tablex.deepcopy

local _M = {}
local template_cache = setmetatable( {}, { __mode = "k" })
local template_environment

local DEBUG = ngx.DEBUG
local CONTENT_LENGTH = "content-length"
local CONTENT_TYPE = "content-type"
local HOST = "host"
local JSON, MULTI, ENCODED = "json", "multi_part", "form_encoded"
local EMPTY = pl_tablex.readonly({})
local templatePrefix = "-"
local templateSuffix ="-"

local function ends_with(str, ending)
  return ending == "" or str:sub(-#ending) == ending
end

local function begins_with(str, beginning)
  return beginning == "" or str:sub(1,#beginning) == beginning
end

local function isTemplate(valueTag)
  return begins_with(valueTag,templatePrefix) and ends_with(valueTag,templateSuffix) 
end

local function stripTemplate(valueTag)
  local innerValue = valueTag:sub(#templatePrefix+1)
  return innerValue:sub(1,-(#templateSuffix+1))
end

local function csplit(str,sep)
  local ret={}
  local n=1
  for w in str:gmatch("([^"..sep.."]*)") do
     ret[n] = ret[n] or w -- only set once (so the blank after a string is ignored)
     if w=="" then
        n = n + 1
     end -- step forwards on a blank but not a string
  end
  return ret
end

local function getTable(tbl,tableKey)
  return tbl[tableKey]
end

local function getItemfromTable(table, itemKey)
  if table ~= nil then   
      return table[itemKey]
  else
      return nil
  end
end

local function isTable(suspectTable,tableName, parentField)
  if(suspectTable == nil) then
      return false
  else
      return (type(suspectTable) == "table")
  end
end

local function getNestedItems(table, keyParts, index)
  local itemKey = keyParts[index+1]
  local obtainedItem = nil
  if itemKey ~=nil then
      obtainedItem = getItemfromTable(table,itemKey)
      if isTable(obtainedItem,itemKey,keyParts[index]) then
          return getNestedItems(obtainedItem,keyParts,index+1)
      end
  end
  return obtainedItem
end

local function getItem(tbl,valueTag)
  local innerValue = stripTemplate(valueTag)
  local keyParts = csplit(innerValue,"%.")
  local tableKey = keyParts[1]
  local containerTable = getTable(tbl,tableKey)
  return getNestedItems(containerTable,keyParts,1)
end

local function getValue(tbl,valueTag)
  if isTemplate(valueTag) then
      local item = getItem(tbl,valueTag)
      return item
  else
      kong.log.info("[kong-plugin-custom-request-transformer] valueTag: ", valueTag)
      return valueTag
  end
end

local function addtoBody(body,destiny,value,index)
  local destinyParts = csplit(destiny,"%.")
  local name = destinyParts[index]
  if(#destinyParts>index) then
      if not body[name] then
          body[name] = {}
      end
      addtoBody(body[name],destiny,value,index+1)
  else
      body[name] = value
  end
  return body
end

local function parse_json(body)
  if body then
    local status, res = pcall(cjson.decode, body)
    if status then
      return res
    end
  end
end

local function get_context()
  local context = {}
  local realIp = ngx.var.remote_addr
  local timestamp = os.date("!%Y-%m-%dT%H:%M:%S.000Z%z")
  if realIp ~= nil then
    context["realIp"] = realIp
    context["timestamp"] = timestamp
  end
  return context
end

local function get_jwt_decode(headers)
  local auth = headers['Authorization'];
  local token = {}
  local err
  if(auth == nil) then
      return {}
  else
      if(begins_with(auth,"Bearer ")) then
        auth = auth:gsub("Bearer","")
        auth = string.gsub(auth, "%s+", "")
        token, err = jwt_decoder:new(auth)
        if err then
          kong.log.err(err)
        end
        if (token == nil) then
          return nil
        else
          return token
        end
      else
        return {}
      end
  end
end

local function decode_args(body)
  if body then
    return ngx_decode_args(body)
  end
  return {}
end

local function get_content_type(content_type)
  if content_type == nil then
    return
  end
  if str_find(content_type:lower(), "application/json", nil, true) then
    return JSON
  elseif str_find(content_type:lower(), "multipart/form-data", nil, true) then
    return MULTI
  elseif str_find(content_type:lower(), "application/x-www-form-urlencoded", nil, true) then
    return ENCODED
  end
end

-- meta table for the sandbox, exposing lazily loaded values
local __meta_environment = {
  __index = function(self, key)
    local lazy_loaders = {
      headers = function(self)
        return get_headers() or EMPTY
      end,
      query_params = function(self)
        return get_uri_args() or EMPTY
      end,
      uri_captures = function(self)
        return (ngx.ctx.router_matches or EMPTY).uri_captures or EMPTY
      end,
      shared = function(self)
        return ((kong or EMPTY).ctx or EMPTY).shared or EMPTY
      end,
    }
    local loader = lazy_loaders[key]
    if not loader then
      -- we don't have a loader, so just return nothing
      return
    end
    -- set the result on the table to not load again
    local value = loader()
    rawset(self, key, value)
    return value
  end,
  __new_index = function(self)
    error("This environment is read-only.")
  end,
}

template_environment = setmetatable({
  -- here we can optionally add functions to expose t1o the sandbox, eg:
  -- tostring = tostring,  -- for example
}, __meta_environment)

local function clear_environment(conf)
  rawset(template_environment, "headers", nil)
  rawset(template_environment, "query_params", nil)
  rawset(template_environment, "uri_captures", nil)
  rawset(template_environment, "shared", nil)
end

local function param_value(source_template, config_array)
  if not source_template or source_template == "" then
    return nil
  end

  -- find compiled templates for this plugin-configuration array
  local compiled_templates = template_cache[config_array]
  if not compiled_templates then
    compiled_templates = {}
    -- store it by `config_array` which is part of the plugin `conf` table
    -- it will be GC'ed at the same time as `conf` and hence invalidate the
    -- compiled templates here as well as the cache-table has weak-keys
    template_cache[config_array] = compiled_templates
  end

  -- Find or compile the specific template
  local compiled_template = compiled_templates[source_template]
  if not compiled_template then
    compiled_template = pl_template.compile(source_template)
    compiled_templates[source_template] = compiled_template
  end

  return compiled_template:render(template_environment)
end

local function iter(config_array)
  return function(config_array, i, previous_name, previous_value)
    i = i + 1
    local current_pair = config_array[i]
    if current_pair == nil then -- n + 1
      return nil
    end

    local current_name, current_value = current_pair:match("^([^:]+):*(.-)$")

    if current_value == "" then
      return i, current_name
    end

    local res, err = param_value(current_value, config_array)
    if err then
      return error("[kong-plugin-custom-request-transformer] failed to render the template ",
        current_value, ", error:", err)
    end

    kong.log.debug("[kong-plugin-custom-request-transformer] template `", current_value,
      "` rendered to `", res, "`")

    return i, current_name, res
  end, config_array, 0
end

local function append_value(current_value, value)
  local current_value_type = type(current_value)

  if current_value_type  == "string" then
    return { current_value, value }
  elseif current_value_type  == "table" then
    table_insert(current_value, value)
    return current_value
  else
    return { value }
  end
end

local function transform_headers(conf)
  local headers = get_headers()
  local headers_to_remove = {}

  headers.host = nil

  -- Remove header(s)
  for _, name, value in iter(conf.remove.headers) do
    name = name:lower()
    if headers[name] then
      headers[name] = nil
      headers_to_remove[name] = true
    end
  end

  -- Rename headers(s)
  for _, old_name, new_name in iter(conf.rename.headers) do
    old_name = old_name:lower()
    if headers[old_name] then
      local value = headers[old_name]
      headers[new_name] = value
      headers[old_name] = nil
      headers_to_remove[old_name] = true
    end
  end

  -- Replace header(s)
  for _, name, value in iter(conf.replace.headers) do
    name = name:lower()
    if headers[name] or name == HOST then
      headers[name] = value
    end
  end

  -- Add header(s)
  for _, name, value in iter(conf.add.headers) do
    name = name:lower()
    if not headers[name] and name ~= HOST then
      headers[name] = value
    end
  end

  -- Append header(s)
  for _, name, value in iter(conf.append.headers) do
    if name:lower() ~= HOST then
      headers[name] = append_value(headers[name], value)
    end
  end

  for name, _ in pairs(headers_to_remove) do
    clear_header(name)
  end

  set_headers(headers)
end

local function transform_querystrings(conf)

  if not (#conf.remove.querystring > 0 or #conf.rename.querystring or
          #conf.replace.querystring > 0 or #conf.add.querystring > 0 or
          #conf.append.querystring > 0) then
    return
  end

  local querystring = pl_copy_table(template_environment.query_params)

  -- Remove querystring(s)
  for _, name, value in iter(conf.remove.querystring) do
    querystring[name] = nil
  end

  -- Rename querystring(s)
  for _, old_name, new_name in iter(conf.rename.querystring) do
    local value = querystring[old_name]
    querystring[new_name] = value
    querystring[old_name] = nil
  end

  for _, name, value in iter(conf.replace.querystring) do
    if querystring[name] then
      querystring[name] = value
    end
  end

  -- Add querystring(s)
  for _, name, value in iter(conf.add.querystring) do
    if not querystring[name] then
      querystring[name] = value
    end
  end

  -- Append querystring(s)
  for _, name, value in iter(conf.append.querystring) do
    querystring[name] = append_value(querystring[name], value)
  end
  set_uri_args(querystring)
end

local function transform_json_body(conf, body, content_length)
  local wrapped, removed, renamed, replaced, added, appended = false, false, false, false, false, false
  local content_length = (body and #body) or 0
  local parameters = parse_json(body)
  local tbl = {}
  local headers = get_headers()
  local jwtdecode = get_jwt_decode(headers)
  local context = get_context()

  if parameters == nil then
    if content_length > 0 then
      return false, nil
    end
    parameters = {}
  end

  tbl["header"]=headers
  tbl["body"]=parameters
  tbl["token"]=jwtdecode
  tbl["context"]=context
  
  if conf.wrap.body == nil then
    conf.wrap.body = ""
  end

  if content_length > 0 and #conf.wrap.body > 0 then
    parameters ={[conf.wrap.body]=parameters}
    wrapped = true
  end


  if content_length > 0 and #conf.remove.body > 0 then
    for _, name, value in iter(conf.remove.body) do
      parameters[name] = nil
      removed = true
    end
  end

  if content_length > 0 and #conf.rename.body > 0 then
    for _, old_name, new_name in iter(conf.rename.body) do
      local value = parameters[old_name]
      parameters[new_name] = value
      parameters[old_name] = nil
      renamed = true
    end
  end

  if content_length > 0 and #conf.replace.body > 0 then
    for _, name, value in iter(conf.replace.body) do
      if parameters[name] then
        parameters[name] = value
        replaced = true
      end
    end
  end

  if #conf.add.body > 0 then
    for _, name, value in iter(conf.add.body) do
      if not parameters[name] then
        parameters = addtoBody(parameters,name,getValue(tbl,value),1)
        added = true
      end
    end
  end

  if #conf.append.body > 0 then
    for _, name, value in iter(conf.append.body) do
      local old_value = parameters[name]
      parameters[name] = append_value(old_value, value)
      appended = true
    end
  end

  if wrapped or removed or renamed or replaced or added or appended then
    return true, cjson.encode(parameters)
  end
end

local function transform_url_encoded_body(conf, body, content_length)
  local renamed, removed, replaced, added, appended = false, false, false, false, false
  local parameters = decode_args(body)

  if content_length > 0 and #conf.remove.body > 0 then
    for _, name, value in iter(conf.remove.body) do
      parameters[name] = nil
      removed = true
    end
  end

  if content_length > 0 and #conf.rename.body > 0 then
    for _, old_name, new_name in iter(conf.rename.body) do
      local value = parameters[old_name]
      parameters[new_name] = value
      parameters[old_name] = nil
      renamed = true
    end
  end

  if content_length > 0 and #conf.replace.body > 0 then
    for _, name, value in iter(conf.replace.body) do
      if parameters[name] then
        parameters[name] = value
        replaced = true
      end
    end
  end

  if #conf.add.body > 0 then
    for _, name, value in iter(conf.add.body) do
      if parameters[name] == nil then
        parameters[name] = value
        added = true
      end
    end
  end

  if #conf.append.body > 0 then
    for _, name, value in iter(conf.append.body) do
      local old_value = parameters[name]
      parameters[name] = append_value(old_value, value)
      appended = true
    end
  end

  if removed or renamed or replaced or added or appended then
    return true, encode_args(parameters)
  end
end

local function transform_multipart_body(conf, body, content_length, content_type_value)
  local removed, renamed, replaced, added, appended = false, false, false, false, false
  local parameters = multipart(body and body or "", content_type_value)

  if content_length > 0 and #conf.rename.body > 0 then
    for _, old_name, new_name in iter(conf.rename.body) do
      if parameters:get(old_name) then
        local value = parameters:get(old_name).value
        parameters:set_simple(new_name, value)
        parameters:delete(old_name)
        renamed = true
      end
    end
  end

  if content_length > 0 and #conf.remove.body > 0 then
    for _, name, value in iter(conf.remove.body) do
      parameters:delete(name)
      removed = true
    end
  end

  if content_length > 0 and #conf.replace.body > 0 then
    for _, name, value in iter(conf.replace.body) do
      if parameters:get(name) then
        parameters:delete(name)
        parameters:set_simple(name, value)
        replaced = true
      end
    end
  end

  if #conf.add.body > 0 then
    for _, name, value in iter(conf.add.body) do
      if not parameters:get(name) then
        parameters:set_simple(name, value)
        added = true
      end
    end
  end

  if removed or renamed or replaced or added or appended then
    return true, parameters:tostring()
  end
end

local function transform_body(conf)
  local content_type_value = get_header(CONTENT_TYPE)
  local content_type = get_content_type(content_type_value)
  if content_type == nil or #conf.rename.body < 1 and
     #conf.remove.body < 1 and #conf.replace.body < 1 and
     #conf.add.body < 1 and #conf.append.body < 1 then
    return
  end

  -- Call req_read_body to read the request body first
  local body = get_raw_body()
  local is_body_transformed = false
  local content_length = (body and #body) or 0

  if content_type == ENCODED then
    is_body_transformed, body = transform_url_encoded_body(conf, body, content_length)
  elseif content_type == MULTI then
    is_body_transformed, body = transform_multipart_body(conf, body, content_length, content_type_value)
  elseif content_type == JSON then
    is_body_transformed, body = transform_json_body(conf, body, content_length)
  end

  if is_body_transformed then
    set_raw_body(body)
    set_header(CONTENT_LENGTH, #body)
  end
end

local function transform_method(conf)
  if conf.http_method then
    local old_method = get_method()
    if old_method == "GET" then
      set_method(conf.http_method:upper())
    end
    if conf.http_method == "GET" or conf.http_method == "HEAD" or conf.http_method == "TRACE" then
      local content_type_value = get_header(CONTENT_TYPE)
      local content_type = get_content_type(content_type_value)
      if content_type == ENCODED then
        -- Also put the body into querystring
        local body = get_raw_body()
        local parameters = decode_args(body)

        -- Append to querystring
        if type(parameters) == "table" and next(parameters) then
          local querystring = get_uri_args()
          for name, value in pairs(parameters) do
            if querystring[name] then
              if type(querystring[name]) == "table" then
                append_value(querystring[name], value)
              else
                querystring[name] = { querystring[name], value }
              end
            else
              querystring[name] = value
            end
          end

          set_uri_args(querystring)
        end
      end
    end

    if conf.http_method == "POST" and old_method == "GET"  then
      local strBody = get_raw_body()
      local body = parse_json(strBody)
      if body == nil then
        body = {}
      end
      local querystring = get_uri_args()
      for name, value in pairs(querystring) do
        body[name]=value;
      end
      set_uri_args({})
     set_raw_body(cjson.encode(body))
    end
  end
end

local function transform_uri(conf)
  if conf.replace.uri then

    local res, err = param_value(conf.replace.uri, conf.replace)
    if err then
      return error("[kong-plugin-custom-request-transformer] failed to render the template ",
        conf.replace.uri, ", error:", err)
    end

    kong.log.debug(DEBUG, "[kong-plugin-custom-request-transformer] template `", conf.replace.uri,
      "` rendered to `", res, "`")

    if res then
      ngx.var.upstream_uri = res
    end
  end
end

function _M.execute(conf)
  clear_environment()
  transform_uri(conf)
  transform_method(conf)
  transform_body(conf)
  transform_headers(conf)
  transform_querystrings(conf)
end

return _M