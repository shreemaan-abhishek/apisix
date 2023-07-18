BEGIN {
    $ENV{TEST_NGINX_FORCE_RESTART_ON_TEST} = 0;
}

use t::APISIX 'no_plan';

repeat_each(1);
no_shuffle();
no_long_string();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    my $http_config = $block->http_config // <<_EOC_;

    # for proxy cache
    lua_shared_dict memory_cache 50m;
_EOC_

    $block->set_value("http_config", $http_config);

    # setup default conf.yaml
    my $extra_yaml_config = $block->extra_yaml_config // <<_EOC_;
plugins:
    - graphql-proxy-cache
_EOC_

    $block->set_value("extra_yaml_config", $extra_yaml_config);

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }

    if ((!defined $block->error_log) && (!defined $block->no_error_log)) {
        $block->set_value("no_error_log", "[error]");
    }
});

run_tests;

__DATA__

=== TEST 1: set route
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
                        "graphql-proxy-cache": {
                            "cache_zone": "memory_cache",
                            "cache_strategy": "memory",
                            "cache_ttl": 3
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:8888": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/graphql"
                }]]
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 2: post method: cache miss
--- request
POST /graphql
{
    "query": "query{persons{id}}"
}
--- more_headers
Content-Type: application/json
--- response_headers
Apisix-Cache-Status: MISS
--- response_body chomp
{"data":{"persons":[{"id":"7"},{"id":"8"},{"id":"9"},{"id":"10"},{"id":"11"},{"id":"12"},{"id":"13"},{"id":"14"},{"id":"15"},{"id":"16"},{"id":"17"},{"id":"18"}]}}



=== TEST 3: post method: cache hit
--- request
POST /graphql
{
    "query": "query{persons{id}}"
}
--- more_headers
Content-Type: application/json
--- response_headers
Apisix-Cache-Status: HIT
--- response_body chomp
{"data":{"persons":[{"id":"7"},{"id":"8"},{"id":"9"},{"id":"10"},{"id":"11"},{"id":"12"},{"id":"13"},{"id":"14"},{"id":"15"},{"id":"16"},{"id":"17"},{"id":"18"}]}}



=== TEST 4: get method: cache miss
--- request
GET /graphql?query=query%7Bpersons%7Bid%7D%7D
--- response_headers
Apisix-Cache-Status: MISS
--- response_body chomp
{"data":{"persons":[{"id":"7"},{"id":"8"},{"id":"9"},{"id":"10"},{"id":"11"},{"id":"12"},{"id":"13"},{"id":"14"},{"id":"15"},{"id":"16"},{"id":"17"},{"id":"18"}]}}



=== TEST 5: get method: cache hit
--- request
GET /graphql?query=query%7Bpersons%7Bid%7D%7D
--- response_headers
Apisix-Cache-Status: HIT
--- response_body chomp
{"data":{"persons":[{"id":"7"},{"id":"8"},{"id":"9"},{"id":"10"},{"id":"11"},{"id":"12"},{"id":"13"},{"id":"14"},{"id":"15"},{"id":"16"},{"id":"17"},{"id":"18"}]}}



=== TEST 6: get with variables: cache miss
--- request
GET /graphql?query=query%20(%24name%3A%20String!)%20%7B%0A%20%20persons(filter%3A%20%7B%20name%3A%20%24name%20%7D)%20%7B%0A%20%20%20%20name%0A%20%20%20%20blog%0A%20%20%20%20githubAccount%0A%20%20%7D%0A%7D%0A&variables=%7B%22name%22%3A%22Niek%22%7D
--- response_headers
Apisix-Cache-Status: MISS
--- response_body chomp
{"data":{"persons":[{"name":"Niek","blog":"https://040code.github.io","githubAccount":"npalm"}]}}



=== TEST 7: get with variables: cache hit
--- request
GET /graphql?query=query%20(%24name%3A%20String!)%20%7B%0A%20%20persons(filter%3A%20%7B%20name%3A%20%24name%20%7D)%20%7B%0A%20%20%20%20name%0A%20%20%20%20blog%0A%20%20%20%20githubAccount%0A%20%20%7D%0A%7D%0A&variables=%7B%22name%22%3A%22Niek%22%7D
--- response_headers
Apisix-Cache-Status: HIT
--- response_body chomp
{"data":{"persons":[{"name":"Niek","blog":"https://040code.github.io","githubAccount":"npalm"}]}}



=== TEST 8: post with variables: cache miss
--- request
POST /graphql
{
    "query": "query($name:String!){persons(filter:{name:$name}){name\nblog\ngithubAccount}}",
    "variables": "{\"name\": \"Niek\"}"
}
--- more_headers
Content-Type: application/json
--- response_headers
Apisix-Cache-Status: MISS
--- response_body chomp
{"data":{"persons":[{"name":"Niek","blog":"https://040code.github.io","githubAccount":"npalm"}]}}



=== TEST 9: post with variables: cache hit
--- request
POST /graphql
{
    "query": "query($name:String!){persons(filter:{name:$name}){name\nblog\ngithubAccount}}",
    "variables": "{\"name\": \"Niek\"}"
}
--- more_headers
Content-Type: application/json
--- response_headers
Apisix-Cache-Status: HIT
--- response_body chomp
{"data":{"persons":[{"name":"Niek","blog":"https://040code.github.io","githubAccount":"npalm"}]}}



=== TEST 10: post by grapgql data: cache miss
--- request
POST /graphql
query {
  persons(filter: { name: "Niek" }) {
    name
    blog
    githubAccount
  }
}
--- more_headers
Content-Type: application/graphql
--- response_headers
Apisix-Cache-Status: MISS
--- response_body chomp
{"data":{"persons":[{"name":"Niek","blog":"https://040code.github.io","githubAccount":"npalm"}]}}



=== TEST 11: post by grapgql data: cache hit
--- request
POST /graphql
query {
  persons(filter: { name: "Niek" }) {
    name
    blog
    githubAccount
  }
}
--- more_headers
Content-Type: application/graphql
--- response_headers
Apisix-Cache-Status: HIT
--- response_body chomp
{"data":{"persons":[{"name":"Niek","blog":"https://040code.github.io","githubAccount":"npalm"}]}}
