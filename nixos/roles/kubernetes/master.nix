# Cluster IP range is 10.0.0.0/24 by default.
# The Kubernetes API server assigns virtual IPs for services from that subnet.
# This must not overlap with "real" subnets.
# It can be set with services.kubernetes.apiserver.serviceClusterIpRange.
# You also have to change flyingcircus.roles.kubernetes.dashboardClusterIP then.

{ config, lib, pkgs, ... }:

with builtins;
with config.flyingcircus.kubernetes.lib;

let
  cfg = config.flyingcircus.roles.kubernetes-master;
  fclib = config.fclib;
  kublib = config.services.kubernetes.lib;
  master = fclib.findOneService "kubernetes-master-master";

  domain = config.networking.domain;
  location = lib.attrByPath [ "parameters" "location" ] "standalone" config.flyingcircus.enc;
  feFQDN = "${config.networking.hostName}.fe.${location}.${domain}";
  srvFQDN = "${config.networking.hostName}.fcio.net";

  # Nginx uses default HTTP(S) ports, API server must use an alternative port.
  apiserverPort = 6443;

  # We allow frontend access to the dashboard and the apiserver for external
  # dashboards and kubectl. Names can be used for both dashboard and API server.
  addresses = [
    "kubernetes.${fclib.currentRG}.fcio.net"
    feFQDN
    srvFQDN
  ];

  # We don't care how the API is accessed but we have to choose one here for
  # the auto-generated configs.
  apiserverMainUrl = "https://${head addresses}:${toString apiserverPort}";

  mkAdminCert = username:
    kublib.mkCert {
      name = username;
      CN = username;
      fields = {
        O = "system:masters";
      };
      privateKeyOwner = username;
    };

  sensuCert =
    kublib.mkCert {
      name = "sensu";
      CN = "sensu";
      fields = {
        O = "default:sensu";
      };
      privateKeyOwner = "sensuclient";
    };

  mkUserKubeConfig = cert:
   kublib.mkKubeConfig cert.name {
    certFile = cert.cert;
    keyFile = cert.key;
    server = apiserverMainUrl;
   };

  kubernetesMakeKubeconfig = pkgs.writeScriptBin "kubernetes-make-kubeconfig" ''
    #!${pkgs.stdenv.shell} -e
    name=''${1:-$USER}

    kubectl get serviceaccount $name &> /dev/null \
      || kubectl create serviceaccount $name > /dev/null

    kubectl get clusterrolebinding cluster-admin-$name &> /dev/null \
      || kubectl create clusterrolebinding cluster-admin-$name \
          --clusterrole=cluster-admin --serviceaccount=default:$name \
          > /dev/null

    token=$(kubectl describe secret $name-token | grep token: | cut -c 13-)

    jq --arg token "$token" '.users[0].user.token = $token' \
      < /etc/kubernetes/$name.kubeconfig > /tmp/$name.kubeconfig

    KUBECONFIG=/tmp/$name.kubeconfig kubectl config view --flatten
    rm /tmp/$name.kubeconfig
  '';

  kubernetesEtcdctl = pkgs.writeScriptBin "kubernetes-etcdctl" ''
    #!${pkgs.stdenv.shell}
    ETCDCTL_API=3 etcdctl --endpoints "https://etcd.local:2379" \
      --cacert /var/lib/kubernetes/secrets/ca.pem \
      --cert /var/lib/kubernetes/secrets/etcd.pem \
      --key /var/lib/kubernetes/secrets/etcd-key.pem \
      "$@"
  '';

  # sudo-srv users get their own cert with cluster-admin permissions.
  adminCerts =
    lib.listToAttrs
      (map
        (user: lib.nameValuePair user (mkAdminCert user))
        (fclib.usersInGroup "sudo-srv")
      );

  allCerts = adminCerts // {
    sensu = sensuCert;
  };

  # Grant view permission for sensu check (identified by sensuCert).
  sensuClusterRoleBinding = pkgs.writeText "sensu-crb.json" (toJSON {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    metadata = {
      name = "sensu";
    };
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io";
      kind = "ClusterRole";
      name = "view";
    };
    subjects = [{
      kind = "User";
      name = "sensu";
    }];
  });

  # The dashboard service defined in NixOS uses a floating ClusterIP, but we
  # want a fixed one that can be included in the nginx config.
  # We have to override the whole service for that.
  dashboardSvc = {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      labels = {
        k8s-addon = "kubernetes-dashboard.addons.k8s.io";
        k8s-app = "kubernetes-dashboard";
        "kubernetes.io/cluster-service" = "true";
        "kubernetes.io/name" = "KubeDashboard";
        "addonmanager.kubernetes.io/mode" = "Reconcile";
      };
      name = "kubernetes-dashboard";
      namespace  = "kube-system";
    };
    spec = {
      clusterIP = cfg.dashboardClusterIP;
      ports = [{
        port = 443;
        targetPort = 8443;
      }];
      selector.k8s-app = "kubernetes-dashboard";
    };
  };

in
{
  options = {
    flyingcircus.roles.kubernetes-master = {

      enable = lib.mkEnableOption "Enable Kubernetes Master (only one per RG; experimental)";

      dashboardClusterIP = lib.mkOption {
        default = "10.0.0.250";
      };

    };
  };

  config = lib.mkIf cfg.enable {

    # Create kubeconfigs for all users with an admin cert (sudo-srv).
    environment.etc =
      lib.mapAttrs'
        (n: v: lib.nameValuePair
          "/kubernetes/${n}.kubeconfig"
          { source = mkUserKubeConfig v; })
        allCerts;

    environment.shellInit = lib.mkAfter ''
      # Root uses the cluster-admin cert generated by NixOS.
      if [[ $UID == 0 ]]; then
        export KUBECONFIG=/etc/kubernetes/cluster-admin.kubeconfig
      else
        export KUBECONFIG=/etc/kubernetes/$USER.kubeconfig
      fi
    '';

    environment.systemPackages = with pkgs; [
      kubectl
      kubernetesEtcdctl
      kubernetesMakeKubeconfig
      sensu-plugins-kubernetes
    ];

    # Policy routing interferes with virtual ClusterIPs handled by kube-proxy, disable it.
    flyingcircus.network.policyRouting.enable = false;

    flyingcircus.activationScripts.kubernetes-apitoken =
      lib.stringAfter [ "users" ] ''
        mkdir -p /var/lib/cfssl
        umask 077
        token=/var/lib/cfssl/apitoken.secret
        echo ${master.password} | md5sum | head -c32 > $token
        chown cfssl $token && chmod 400 $token
      '';

    flyingcircus.services.sensu-client.checks = let
      bin = "${pkgs.sensu-plugins-kubernetes}/bin";
      cfg = "--kube-config /etc/kubernetes/sensu.kubeconfig";
    in
    {
      kube-apiserver = {
        notification = "Kubernetes API server is not working";
        command = ''
          ${bin}/check-kube-apiserver-available.rb ${cfg}
        '';
      };

      kube-dashboard = {
        notification = "Kubernetes dashboard is not working";
        command = ''
          ${bin}/check-kube-service-available.rb -l kubernetes-dashboard ${cfg}
        '';
      };

      kube-dns = {
        notification = "Kubernetes DNS is not working";
        command = ''
          ${bin}/check-kube-service-available.rb -l kube-dns ${cfg}
        '';
      };

    };

    networking.firewall = {
      allowedTCPPorts = [ apiserverPort ];
    };

    services.kubernetes = {
      addons.dashboard.enable = true;
      addonManager.addons.kubernetes-dashboard-svc = lib.mkForce dashboardSvc;
      apiserver.extraSANs = addresses;
      # Changing the masterAddress is tricky and requires manual intervention.
      # This would break automatic certificate management with certmgr.
      # SRV seems like the safest choice here.
      masterAddress = srvFQDN;
      # We already do that in the activation script.
      pki.genCfsslAPIToken = false;
      roles = [ "master" ];
    };

    # Serves public Kubernetes dashboard.
    flyingcircus.services.nginx.enable = true;

    services.nginx.virtualHosts = {
      "${head addresses}" = {
        enableACME = true;
        serverAliases = tail addresses;
        forceSSL = true;
        locations = {
          "/" = {
            proxyPass = "https://${cfg.dashboardClusterIP}";
          };
        };
      };
    };

    services.kubernetes.pki.certs = allCerts;

    systemd.services = {
      fc-kubernetes-monitoring-setup = rec {
        description = "Setup permissions for monitoring";
        requires = [ "kube-apiserver.service" ];
        after = requires;
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.kubectl ];
        script = ''
          kubectl apply -f ${sensuClusterRoleBinding}
        '';
        serviceConfig = {
          Environment = "KUBECONFIG=/etc/kubernetes/cluster-admin.kubeconfig";
          Type = "oneshot";
          RemainAfterExit = true;
        };
      };
    } // lib.mapAttrs'
      mkUnitWaitForCerts
      {
        "etcd" = [ "etcd" ];
        "flannel" = [ "flannel-client" ];
        "kube-addon-manager" = [ "kube-addon-manager" ];

        "kube-apiserver" = [
          "kube-apiserver"
          "kube-apiserver-kubelet-client"
          "kube-apiserver-etcd-client"
          "service-account"
        ];

        "kube-proxy" = [ "kube-proxy-client" ];

        "kube-controller-manager" = [
          "kube-controller-manager"
          "kube-controller-manager-client"
          "service-account"
        ];
      };

  };

}
