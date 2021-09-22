--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local require = require
local local_conf = require("apisix.core.config_local").local_conf()
local core = require("apisix.core")
local resty_consul = require('resty.consul')
local ipmatcher = require("resty.ipmatcher")
local http = require('resty.http')
local ipairs = ipairs
local error = error
local ngx = ngx
local unpack = unpack
local pairs = pairs
local ngx_timer_at = ngx.timer.at
local ngx_timer_every = ngx.timer.every
local log = core.log
local json_delay_encode = core.json.delay_encode

-- LOCAL VARIABLES
local applications = core.table.new(0, 5)
local default_service
local default_weight -- default set as `schema.weight`

local events
local events_list
local consul_apps

local schema = {
    type = "object",
    properties = {
        -- consul servers address
        servers = {type = "array", minItems = 1, items = {type = "string"}},
        -- all timeout settings for interacting with consul server
        timeout = {
            type = "object",
            properties = {
                connect = {type = "integer", minValue = 1, default = 2000},
                read = {type = "integer", minValue = 1, default = 2000}
            },
            default = {connect = 2000, read = 2000}
        },
        fetch_interval = {type = "integer", minValue = 1, default = 30},

        -- special the expression used to filter the registered services
        filter = {type = "string"},

        -- special the default weight for unspecified services
        weight = {type = "integer", minimum = 1, default = 1},

        -- for default back-end service like 404 service
        default_service = {
            type = "object",
            properties = {
                host = {type = "string"},
                port = {type = "integer"},
                metadata = {
                    type = "object",
                    properties = {
                        fail_timeout = {type = "integer", default = 1},
                        weight = {type = "integer", default = 1},
                        max_fails = {type = "integer", default = 1}
                    },
                    default = {fail_timeout = 1, weight = 1, max_fails = 1}
                }
            }
        }
    },

    required = {"servers"}
}

local _M = {version = 0.1}

local function discovery_consul_callback(data, event, source, pid)
    applications = data
    log.info("update local variable applications, event is: ", event,
             "source: ", source, "server pid:", pid, ", applications: ",
             core.json.encode(applications, true))
end

local function format_consul_params(consul_conf)
    local consul_servers_list = core.table.new(0, #consul_conf.servers)
    local args

    if consul_conf.filter and #consul_conf.filter > 0 then
        args = {filter = consul_conf.filter}
    end

    for _, s in ipairs(consul_conf.servers) do
        local scheme, host, port, path = unpack(http.parse_uri(nil, s))
        if scheme ~= "http" then
            return nil,
                   "only support consul http schema address, e.g.: http://address:port"
        elseif path ~= "/" or core.string.has_suffix(s, "/") then
            return nil,
                   "invalid consul server address, the valid format: http://address:port"
        end

        core.table.insert(consul_servers_list, {
            host = host,
            port = port,
            connect_timeout = consul_conf.timeout.connect,
            read_timeout = consul_conf.timeout.read,
            server_name_key = s .. "/v1/agent/services/",
            weight = consul_conf.weight,
            default_args = args,
            fetch_interval = consul_conf.fetch_interval
        })
    end

    return consul_servers_list
end

local function update_application(server_name_prefix, data)
    local sn
    local up_apps = core.table.new(0, #data)
    local weight = default_weight

    for _, service in pairs(data) do
        if not service then goto CONTINUE end

        sn = server_name_prefix .. service.Service
        local nodes = up_apps[sn]
        if not nodes then
            nodes = core.table.new(1, 0)
            up_apps[sn] = nodes
        end

	local sid = service.ID

        local host = service.Address
        if not ipmatcher.parse_ipv4(host) and not ipmatcher.parse_ipv6(host) then
            log.error("no valid service address can be found, service: ", sid)
            goto CONTINUE
        end

        local port = service.Port
        if port <= 0 then
            log.error("no valid service port can be found, service: ", sid)
            goto CONTINUE
        end

        local sw = weight
        if service.Weight and
		service.Weight.Passing and
		service.Weight.Passing > 0
		then
		sw = service.Weight.Passing
	end
        core.table.insert(nodes, {
            host = host,
            port = port,
            weight = sw
        })
        ::CONTINUE::
    end

    -- clean old unused data
    local old_apps = consul_apps[server_name_prefix] or {}
    for k, _ in pairs(old_apps) do applications[k] = nil end
    core.table.clear(old_apps)

    for k, v in pairs(up_apps) do applications[k] = v end
    consul_apps[server_name_prefix] = up_apps

    log.info("updated applications: ", core.json.encode(applications))
end

function _M.connect(premature, consul_server)
    if premature then return end

    local consul_client = resty_consul:new({
        host = consul_server.host,
        port = consul_server.port,
        connect_timeout = consul_server.connect_timeout,
        read_timeout = consul_server.read_timeout,
        default_args = consul_server.default_args
    })
    log.info("attempts to connect consul_server: ",
             json_delay_encode(consul_server, true))

    local services_api_prefix = "/agent/services"
    -- query all registered services in consul
    local result, err = consul_client:get(services_api_prefix)
    local error_info = (err ~= nil and err) or
                           ((result ~= nil and result.status ~= 200) and
                               result.status)
    if error_info then
        log.error("connect consul: ", consul_server.server_name_key,
                  " by services prefix: ", consul_server.services_api_prefix,
                  ", got result: ", json_delay_encode(result, true),
                  ", with error: ", error_info)
        goto ERR
    end

    -- decode body, decode json, update application, error handling
    if result.body then
        log.notice("consul server: ", consul_server.server_name_key,
                   ", header: ", core.json.encode(result.headers, true),
                   ", body: ", core.json.encode(result.body, true))

        update_application(consul_server.server_name_key, result.body)
        -- update events
        local ok, err = events.post(events_list._source, events_list.updating,
                                    applications)
        if not ok then
            log.error("post_event failure with ", events_list._source,
                      ", update application error: ", err)
        end

        -- terminate this connect life-cycle
        return
    end

    ::ERR::
    -- FIXME: use exponential backoff instead of connect immediately
    local ok, err = ngx_timer_at(0, _M.connect, consul_server)
    if not ok then
        log.error("create ngx_timer_at got error: ", err)
        return
    end
end

function _M.all_nodes() return applications end

function _M.nodes(service_name)
    if not applications then
        log.error("applications is nil, failed to fetch nodes for: ",
                  service_name)
        return
    end

    local resp_list = applications[service_name]
    if not resp_list then -- cannot find any nodes by specified service name
        log.error("fetch nodes failed by: ", service_name,
                  ", return default services")
        return default_service and {default_service}
    end

    log.info("process id: ", ngx.worker.id(), ", applications: [", service_name,
             "] = ", json_delay_encode(resp_list, true))

    return resp_list
end

function _M.dump_data()
    return {config = local_conf.discovery.consul, services = applications}
end

function _M.init_worker()
    -- fetch consul registered servers and update to applications
    local consul_conf = local_conf.discovery.consul
    if not consul_conf or not consul_conf.servers or #consul_conf.servers == 0 then
        error("do not set consul servers correctly!")
        return
    end

    local ok, err = core.schema.check(schema, consul_conf)
    if not ok then
        error("invalid consul configuration: " .. err)
        return
    end

    events = require("resty.worker.events")
    events_list = events.event_list("discovery_consul_update_application",
                                    "updating")

    if 0 ~= ngx.worker.id() then
        -- register callback function for workers process only
        events.register(discovery_consul_callback, events_list._source,
                        events_list.updating)
        return
    end

    -- TIPS: ONLY THE MASTER PROCESS WILL EXECUTE THE FOLLOWING CODE

    log.notice("got consul_conf: ", core.json.encode(consul_conf))
    default_weight = consul_conf.weight

    -- set default back-end service, used when the other services cannot be found
    if consul_conf.default_service then
        default_service = consul_conf.default_service
        default_service.weight = default_weight
    end

    local consul_servers_list, err = format_consul_params(consul_conf)
    if err then
        error("failed to format consul server: " .. err)
        return
    end
    log.info("consul_servers_list: ", core.json.encode(consul_servers_list))

    -- initialize for insert the applications registered to consul
    consul_apps = core.table.new(0, 1)
    for _, server in ipairs(consul_servers_list) do
        local ok, err = ngx_timer_at(0, _M.connect, server)
        if not ok then
            error("create consul client instance got error: " .. err)
            return
        end

        ngx_timer_every(server.fetch_interval, _M.connect, server)
    end
end

return _M;
