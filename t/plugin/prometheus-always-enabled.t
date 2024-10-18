use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_shuffle();
no_root_location();

run_tests;

__DATA__

=== TEST 1: test prometheus is always enabled
--- yaml_config
plugins: [] # disable all plugins
apisix:     # to enable stream subsystem
  stream_proxy:
    tpc:
      - 9100
--- stream_request
example message
--- log_level: info
--- error_log
apisix.plugins.prometheus.exporter http_init
apisix.plugins.prometheus.exporter stream_init
