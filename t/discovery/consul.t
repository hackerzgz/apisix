#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
use t::APISIX 'no_plan';

repeat_each(1);
log_level('info');
no_root_location();
no_shuffle();

add_block_preprocessor(sub {
    my ($block) = @_;

    my $http_config = $block->http_config // <<_EOC_;

    server {
        listen 20999;

	location / {
	    content_by_lua_block {
	        ngx.say("[default_service] missing consul services")
	    }
	}
    }

    server {
        listen 30511;

	location /hello {
	    content_by_lua_block {
	        ngx.say("server 1")
	    }
	}
    }
    server {
        listen 30512;

	location /hello {
	    content_by_lua_block {
	        ngx.say("server 2")
	    }
	}
    }
    server {
        listen 30513;

	location /hello {
	    content_by_lua_block {
	        ngx.say("server 3")
	    }
	}
    }
    server {
        listen 30514;

	location /hello {
	    content_by_lua_block {
	        ngx.say("server 4")
	    }
	}
    }
_EOC_

    $block->set_value("http_config", $http_config);
});

our $yaml_config = <<_EOC_;
apisix:
  node_listen: 1984
  config_center: yaml
  enable_admin: false

discovery:
  consul:
    services:
      - "http://127.0.0.1:8500"
      - "http://127.0.0.1:8600"
    timeout:
      connect: 1000
      read: 1000
    weight: 1
    fetch_interval: 30
    default_service:
      host: "127.0.0.1"
      port: 20999
      metadata:
        fail_timeout: 1
        weight: 1
        max_fails: 1
_EOC_

run_tests();

__DATA__

=== TEST 1: prepare consul registered services
--- config
location /consul1 {
    rewrite  ^/consul1/(.*) /v1/$1 break;
    proxy_pass http://127.0.0.1:8500;
}

location /consul2 {
    rewrite  ^/consul2/(.*) /v1/$1 break;
    proxy_pass http://127.0.0.1:8600;
}
--- pipelined_requests eval
[
    "PUT /consul1/agent/service/deregister/webpages.1"
    "PUT /consul1/agent/service/deregister/webpages.2"
    "PUT /consul2/agent/service/deregister/webpages.3"
    "PUT /consul2/agent/service/deregister/webpages.4"

    "PUT /consul1/agent/service/register\n" . "{\"ID\":\"webpages.1\",\"Name\":\"webpages\",\"Address\":\"127.0.0.1\",\"Port\":30511,\"Weights\":{\"Passing\":1,\"Warning\":1}}"
    "PUT /consul1/agent/service/register\n" . "{\"ID\":\"webpages.2\",\"Name\":\"webpages\",\"Address\":\"127.0.0.1\",\"Port\":30512\"Weights\":{\"Passing\":1,\"Warning\":1}}"
    "PUT /consul2/agent/service/register\n" . "{\"ID\":\"webpages.3\",\"Name\":\"webpages\",\"Address\":\"127.0.0.1\",\"Port\":30513,\"Weights\":{\"Passing\":1,\"Warning\":1}}"
    "PUT /consul2/agent/service/register\n" . "{\"ID\":\"webpages.4\",\"Name\":\"webpages\",\"Address\":\"127.0.0.1\",\"Port\":30514,\"Weights\":{\"Passing\":1,\"Warning\":1}}"
]
--- response_body_like eval
[
    "HTTP/1.1 200 OK",
    "HTTP/1.1 200 OK",
    "HTTP/1.1 200 OK",
    "HTTP/1.1 200 OK",

    "HTTP/1.1 200 OK",
    "HTTP/1.1 200 OK",
    "HTTP/1.1 200 OK",
    "HTTP/1.1 200 OK",
]



=== TEST 2: test consul server 1
--- yaml_config eval: $::yaml_config
--- apisix_yaml
routers:
  -
    uri: /*
    upstream:
      service_name: http://127.0.0.1:8500/v1/agent/services/webpages/
      discovery_type: consul
      type: roundrobin
#END
--- pipelined_requests eval
[
    "GET /hello",
    "GET /hello",
]
--- response_body_like eval
[
    qr/server [1-2]\n/,
    qr/server [1-2]\n/,
]
--- no_error_log
[error, error]



=== TEST 3: test consul server 2
--- yaml_config eval: $::yaml_config
--- apisix_yaml
routes:
  -
    uri: /*
    upstream:
      service_name: http://127.0.0.1:8600/v1/agent/services/webpages/
      discovery_type: consul
      type: roundrobin
#END
--- pipelined_requests eval
[
    "GET /hello",
    "GET /hello"
]
--- response_body_like eval
[
    qr/server [3-4]\n/,
    qr/server [3-4]\n/,
]
--- no_error_log
[error, error]



=== TEST 4: test mini consul config
--- yaml_config
apisix:
  node_listen: 1984
  config_center: yaml
  enable_admin: false

discovery:
  consul:
    servers:
      - "http://127.0.0.1:8500"
      - "http://127.0.0.1:8600"
#END
--- apisix_yaml
routes:
  -
    uri: /hello
    upstream:
      service_name: http://127.0.0.1:8500/v1/agent/services/webpages/
      discovery_type: consul
      type: roundrobin
#END
--- request
GET /hello
--- response_body_like eval
qr/server [1-2]/



=== TEST 5: test invalid service name
sometimes the consul key maybe deleted by mistake

--- yaml_config eval: $::yaml_config
--- apisix_yaml
routes:
  -
    uri: /*
    upstream:
      service_name: http://127.0.0.1:8600/v1/agent/services/deleted_keys/
      discovery_type: consul
      type: roundrobin
#END
--- pipelined_requests eval
[
    "GET /hello_api",
    "GET /hello_api"
]
--- response_body eval
[
    "[default_service] missing consul services\n",
    "[default_service] missing consul services\n",
]
--- grep_error_log_out eval
[
    "fetch nodes failed by http://127.0.0.1:8600/v1/agent/services/deleted_keys/, return default service",
    "fetch nodes failed by http://127.0.0.1:8600/v1/agent/services/deleted_keys/, return default service"
]



=== TEST 6: test filter services
filter specific registered services like consul itself and other infrastruction services
--- yaml_config
apisix:
  node_listen: 1984
  config_center: yaml
  enable_admin: false

discovery:
  consul:
    services:
      - "http://127.0.0.1:8500"
    timeout:
      connect: 1000
      read: 1000
    filter: "Service!=webpages"
    weight: 1
    fetch_interval: 30
    default_service:
      host: "127.0.0.1"
      port: 20999
      metadata:
        fail_timeout: 1
        weight: 1
        max_fails: 1
#END
--- apisix_yaml
routers:
  -
  uri: /*
    upstream:
      service_name: http://127.0.0.1:8500/v1/agent/services/webpages/
      discovery_type: consul
      type: roundrobin
#END
--- request
GET /hello
--- response_body eval
"[default_service] missing consul services\n"



=== TEST 7: test register and unregister nodes
--- yaml_config eval: $::yaml_config
--- apisix_yaml
routes:
  -
    uri: /*
    upstream:
      service_name: http://127.0.0.1:8500/v1/agent/services/webpages/
      discovery_type: consul
      type: roundrobin
#END
--- config
location /v1/agent {
    proxy_pass http://127.0.0.1:8500;
}
location /sleep {
    content_by_lua_block {
        local args = ngx.req.get_uri_args()
        local sec = args.sec or "2"
        ngx.sleep(tonumber(sec))
        ngx.say("ok")
    }
}
--- timeout: 6
--- request eval
[
    "PUT /v1/agent/services/deregister/webpages.1",
    "PUT /v1/agent/services/deregister/webpages.2",
    "PUT /v1/agent/service/register\n" . "{\"ID\":\"webpages.1\",\"Name\":\"webpages\",\"Address\":\"127.0.0.1\",\"Port\":30513,\"Weights\":{\"Passing\":1,\"Warning\":1}}"
    "PUT /v1/agent/service/register\n" . "{\"ID\":\"webpages.2\",\"Name\":\"webpages\",\"Address\":\"127.0.0.1\",\"Port\":30514,\"Weights\":{\"Passing\":1,\"Warning\":1}}"
    "GET /sleep",

    "GET /hello?random1",
    "GET /hello?random2",
    "GET /hello?random3",
    "GET /hello?random4",

    "PUT /v1/agent/services/deregister/webpages.1",
    "PUT /v1/agent/services/deregister/webpages.2",
    "PUT /consul1/agent/service/register\n" . "{\"ID\":\"webpages.1\",\"Name\":\"webpages\",\"Address\":\"127.0.0.1\",\"Port\":30511,\"Weights\":{\"Passing\":1,\"Warning\":1}}"
    "PUT /consul1/agent/service/register\n" . "{\"ID\":\"webpages.2\",\"Name\":\"webpages\",\"Address\":\"127.0.0.1\",\"Port\":30512\"Weights\":{\"Passing\":1,\"Warning\":1}}"
    "GET /sleep?sec=5",

    "GET /hello?random1",
    "GET /hello?random2",
    "GET /hello?random3",
    "GET /hello?random4",
]
--- response_body_like eval
[
    qr/^$/,
    qr/^$/,
    qr/^$/,
    qr/^$/,
    qr/ok\n/,

    qr/server [3-4]\n/,
    qr/server [3-4]\n/,
    qr/server [3-4]\n/,
    qr/server [3-4]\n/,

    qr/^$/,
    qr/^$/,
    qr/^$/,
    qr/^$/,
    qr/ok\n/,

    qr/server [1-2]\n/,
    qr/server [1-2]\n/,
    qr/server [1-2]\n/,
    qr/server [1-2]\n/
]



=== TEST 8: prepare healthy and unhealthy nodes
--- config
location /v1/agent {
    proxy_pass http://127.0.0.1:8500;
}
--- request eval
[
    "PUT /v1/agent/services/deregister/webpages.2",
    "PUT /v1/agent/service/register\n" . "{\"ID\":\"webpages.2\",\"Name\":\"webpages\",\"Address\":\"127.0.0.2\",\"Port\":1988,\"Weights\":{\"Passing\":1,\"Warning\":1}}"
]
--- response_header_like eval
[
    'HTTP1.1 200 OK',
    'HTTP1.1 200 OK',
]



=== TEST 9: test health checker
--- yaml_config eval: $::yaml_config
--- apisix_yaml
routes:
  -
    uris:
        - /hello
    upstream_id: 1
upstreams:
    -
      service_name: http://127.0.0.1:8500/v1/agent/services/webpages
      discovery_type: consul
      type: roundrobin
      id: 1
      checks:
        active:
            http_path: "/hello"
            healthy:
                interval: 1
                successes: 1
            unhealthy:
                interval: 1
                http_failures: 1
#END
--- config
    location /thc {
        content_by_lua_block {
            local json = require("toolkit.json")
            local t = require("lib.test_admin")
            local http = require "resty.http"
            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/hello"
            local httpc = http.new()
            httpc:request_uri(uri, {method = "GET"})
            ngx.sleep(3)

            local code, body, res = t.test('/v1/healthcheck',
                ngx.HTTP_GET)
            res = json.decode(res)
            table.sort(res[1].nodes, function(a, b)
                return a.host < b.host
            end)
            ngx.say(json.encode(res))

            local code, body, res = t.test('/v1/healthcheck/upstreams/1',
                ngx.HTTP_GET)
            res = json.decode(res)
            table.sort(res.nodes, function(a, b)
                return a.host < b.host
            end)
            ngx.say(json.encode(res))
        }
    }
--- request
GET /thc
--- response_body
[{"healthy_nodes":[{"host":"127.0.0.1","port":30511,"priority":0,"weight":1}],"name":"upstream#/upstreams/1","nodes":[{"host":"127.0.0.1","port":30511,"priority":0,"weight":1},{"host":"127.0.0.2","port":1988,"priority":0,"weight":1}],"src_id":"1","src_type":"upstreams"}]
{"healthy_nodes":[{"host":"127.0.0.1","port":30511,"priority":0,"weight":1}],"name":"upstream#/upstreams/1","nodes":[{"host":"127.0.0.1","port":30511,"priority":0,"weight":1},{"host":"127.0.0.2","port":1988,"priority":0,"weight":1}],"src_id":"1","src_type":"upstreams"}


=== TEST 10: retry when Consul server cannot be reached (long connect type)
--- yaml_config
apisix:
  node_listen: 1984
  config_center: yaml
  enable_admin: false

discovery:
  consul:
    servers:
      - "http://127.0.0.1:8501"
    fetch_interval: 3
    default_service:
      host: "127.0.0.1"
      port: 20999
#END
--- apisix_yaml
router:
  -
    url: /*
    upstream:
      service_name: http://127.0.0.1:8501/v1/agent/services/webpages
      discovery_type: consul
      type: roundrobin
#END
--- timeout: 4
--- config
location /sleep {
    content_by_lua_block {
        local args = ngx.req.get_uri_args()
	local sec = args.sec or "2"
	ngx.sleep(tonumber(sec))
	ngx.say("ok")
    }
}
--- request
GET /sleep?sec=3
--- response_body
ok
--- grep_error_log eval
qr/retry connecting consul after \d seconds/
--- grep_error_log_out
retry connecting consul after 1 seconds
retry connecting consul after 4 seconds
