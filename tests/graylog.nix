import ./make-test.nix ({ pkgs, lib, ... }:
let
  ipv4 = "192.168.101.1";
  ipv6 = "2001:db8:f030:1c3::1";
in {
  name = "graylog";
  machine =
    { config, ... }:
    {
      imports = [
        ../nixos
        ../nixos/roles
      ];

      virtualisation.memorySize = 4096;

      flyingcircus.roles.loghost.enable = true;
      networking.domain = "fcio.net";

      services.telegraf.enable = true;  # set in infra/fc but not in infra/testing

      flyingcircus.enc.parameters = {
        directory_password = "asdf";
        resource_group = "test";
        interfaces.srv = {
          mac = "52:54:00:12:34:56";
          networks = {
            "192.168.101.0/24" = [ ipv4 ];
            "2001:db8:f030:1c3::/64" = [ ipv6 ];
          };
          gateways = {};
        };
      };

      users.groups.login = {
        members = [];
      };

      flyingcircus.encServices = [
        { service = "loghost-server";
          address = "machine.fcio.net";
        }
      ];
      networking.extraHosts = ''
        ${ipv4} machine.fcio.net
        ${ipv6} machine.fcio.net
      '';

    };
  testScript = { nodes, ... }:
  let
    config = nodes.machine.config;
    sensuChecks = config.flyingcircus.services.sensu-client.checks;
    graylogCheck = lib.replaceChars ["\n"] [" "] sensuChecks.graylog_ui.command;
    graylogApi = "${pkgs.fc.agent}/bin/fc-graylog --api http://machine.fcio.net:9001/api get -l";
  in ''
    $machine->waitForUnit("haproxy.service");
    $machine->waitForUnit("mongodb.service");
    $machine->waitForUnit("elasticsearch.service");
    $machine->waitForUnit("graylog.service");
    $machine->waitForUnit("nginx.service");

    subtest "elasticsearch should have a graylog index", sub {
      $machine->succeed("curl http://machine.fcio.net:9200/_cat/indices?v | grep -q graylog_0");
    };

    subtest "graylog API should respond", sub {
      $machine->succeed("${graylogApi} / | grep -q cluster_id");
    };

    subtest "config script must create telegraf user", sub {
      $machine->waitForUnit("fc-graylog-config.service");
      $machine->succeed("${graylogApi} /users | grep -q telegraf");
    };

    subtest "sensu check should be green", sub {
      $machine->succeed("${graylogCheck}");
    };

    subtest "sensu check should be red after shutting down graylog", sub {
      $machine->stopJob("graylog.service");
      $machine->waitUntilFails("${graylogApi} / | grep -q cluster_id");
      $machine->mustFail("${graylogCheck}");
    };

    subtest "service user should be able to write to local config dir", sub {
      $machine->succeed('sudo -u graylog touch /etc/local/graylog/graylog.json');
    };

    subtest "secret files should have correct permissions", sub {
      $machine->succeed("stat /etc/local/graylog/password -c %a:%U:%G | grep '660:graylog:service'");
      $machine->succeed("stat /etc/local/graylog/password_secret -c %a:%U:%G | grep '660:graylog:service'");
      $machine->succeed("stat /run/graylog/graylog.conf -c %a:%U:%G | grep '440:graylog:service'");
    };
  '';
})
