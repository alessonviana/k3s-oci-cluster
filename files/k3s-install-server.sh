#!/bin/bash

check_os() {
  name=$(cat /etc/os-release | grep ^NAME= | sed 's/"//g')
  clean_name=$${name#*=}

  version=$(cat /etc/os-release | grep ^VERSION_ID= | sed 's/"//g')
  clean_version=$${version#*=}
  major=$${clean_version%.*}
  minor=$${clean_version#*.}
  
  if [[ "$clean_name" == "Ubuntu" ]]; then
    operating_system="ubuntu"
  elif [[ "$clean_name" == "Oracle Linux Server" ]]; then
    operating_system="oraclelinux"
  else
    operating_system="undef"
  fi

  echo "K3S install process running on: "
  echo "OS: $operating_system"
  echo "OS Major Release: $major"
  echo "OS Minor Release: $minor"
}

wait_lb() {
while [ true ]
do
  curl --output /dev/null --silent -k https://${k3s_url}:6443
  if [[ "$?" -eq 0 ]]; then
    break
  fi
  sleep 5
  echo "wait for LB"
done
}

install_helm() {
  curl -fsSL -o /root/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 /root/get_helm.sh
  /root/get_helm.sh
}

install_and_configure_traefik2() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  # Install Helm
  install_helm

  # Add traefik helm repo
  kubectl create ns traefik
  helm repo add traefik https://helm.traefik.io/traefik
  helm repo update

  TRAEFIK_VALUES_FILE=/root/traefik2_values.yaml
  render_traefil2_config
  helm install --namespace=traefik -f $TRAEFIK_VALUES_FILE traefik traefik/traefik
}

render_traefil2_config() {
cat << 'EOF' > "$TRAEFIK_VALUES_FILE"
service:
  enabled: true
  type: NodePort

# Configure ports
ports:
  # The name of this one can't be changed as it is used for the readiness and
  # liveness probes, but you can adjust its config to your liking
  traefik:
    port: 9000
    # Use hostPort if set.
    # hostPort: 9000
    #
    # Use hostIP if set. If not set, Kubernetes will default to 0.0.0.0, which
    # means it's listening on all your interfaces and all your IPs. You may want
    # to set this value if you need traefik to listen on specific interface
    # only.
    # hostIP: 192.168.100.10

    # Override the liveness/readiness port. This is useful to integrate traefik
    # with an external Load Balancer that performs healthchecks.
    # Default: ports.traefik.port
    # healthchecksPort: 9000

    # Override the liveness/readiness scheme. Useful for getting ping to
    # respond on websecure entryPoint.
    # healthchecksScheme: HTTPS

    # Defines whether the port is exposed if service.type is LoadBalancer or
    # NodePort.
    #
    # You SHOULD NOT expose the traefik port on production deployments.
    # If you want to access it from outside of your cluster,
    # use `kubectl port-forward` or create a secure ingress
    expose: false
    # The exposed port for this service
    exposedPort: 9000
    # The port protocol (TCP/UDP)
    protocol: TCP
  web:
    port: 8000
    # hostPort: 8000
    expose: true 
    exposedPort: 80
    # The port protocol (TCP/UDP)
    protocol: TCP
    # Use nodeport if set. This is useful if you have configured Traefik in a
    # LoadBalancer
    nodePort: ${ingress_controller_http_nodeport}
    # Port Redirections
    # Added in 2.2, you can make permanent redirects via entrypoints.
    # https://docs.traefik.io/routing/entrypoints/#redirection
    # redirectTo: websecure
    #
    # Trust forwarded  headers information (X-Forwarded-*).
    # forwardedHeaders:
    #   trustedIPs: []
    #   insecure: false
    #
    # Enable the Proxy Protocol header parsing for the entry point
    proxyProtocol:
      trustedIPs:
        - 0.0.0.0/0
        - 127.0.0.1/32
      insecure: false
  websecure:
    port: 8443
    # hostPort: 8443
    expose: true
    exposedPort: 443
    # The port protocol (TCP/UDP)
    protocol: TCP
    nodePort: ${ingress_controller_https_nodeport}
    # Enable HTTP/3.
    # Requires enabling experimental http3 feature and tls.
    # Note that you cannot have a UDP entrypoint with the same port.
    # http3: true
    # Set TLS at the entrypoint
    # https://doc.traefik.io/traefik/routing/entrypoints/#tls
    tls:
      enabled: true
      # this is the name of a TLSOption definition
      options: ""
      certResolver: ""
      domains: []
      # - main: example.com
      #   sans:
      #     - foo.example.com
      #     - bar.example.com
    #
    # Trust forwarded  headers information (X-Forwarded-*).
    # forwardedHeaders:
    #   trustedIPs: []
    #   insecure: false
    #
    # Enable the Proxy Protocol header parsing for the entry point
    proxyProtocol:
      trustedIPs:
        - 0.0.0.0/0
        - 127.0.0.1/32
      insecure: false
    #
    # One can apply Middlewares on an entrypoint
    # https://doc.traefik.io/traefik/middlewares/overview/
    # https://doc.traefik.io/traefik/routing/entrypoints/#middlewares
    # /!\ It introduces here a link between your static configuration and your dynamic configuration /!\
    # It follows the provider naming convention: https://doc.traefik.io/traefik/providers/overview/#provider-namespace
    # middlewares:
    #   - namespace-name1@kubernetescrd
    #   - namespace-name2@kubernetescrd
    middlewares: []
  metrics:
    # When using hostNetwork, use another port to avoid conflict with node exporter:
    # https://github.com/prometheus/prometheus/wiki/Default-port-allocations
    port: 9100
    # hostPort: 9100
    # Defines whether the port is exposed if service.type is LoadBalancer or
    # NodePort.
    #
    # You may not want to expose the metrics port on production deployments.
    # If you want to access it from outside of your cluster,
    # use `kubectl port-forward` or create a secure ingress
    expose: false
    # The exposed port for this service
    exposedPort: 9100
    # The port protocol (TCP/UDP)
    protocol: TCP
EOF
}

render_nginx_config(){
cat << 'EOF' > "$NGINX_RESOURCES_FILE"
---
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller-loadbalancer
  namespace: ingress-nginx
spec:
  selector:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
  ports:
    - name: http
      port: 80
      protocol: TCP
      targetPort: 80
      nodePort: ${ingress_controller_http_nodeport}
    - name: https
      port: 443
      protocol: TCP
      targetPort: 443
      nodePort: ${ingress_controller_https_nodeport}
  type: NodePort
---
apiVersion: v1
data:
  allow-snippet-annotations: "true"
  enable-real-ip: "true"
  proxy-real-ip-cidr: "0.0.0.0/0"
  proxy-body-size: "20m"
  use-proxy-protocol: "true"
kind: ConfigMap
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
    app.kubernetes.io/version: 1.1.1
    helm.sh/chart: ingress-nginx-4.0.16
  name: ingress-nginx-controller
  namespace: ingress-nginx
EOF
}

render_staging_issuer(){
STAGING_ISSUER_RESOURCE=$1
cat << 'EOF' > "$STAGING_ISSUER_RESOURCE"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
 name: letsencrypt-staging
 namespace: cert-manager
spec:
 acme:
   # The ACME server URL
   server: https://acme-staging-v02.api.letsencrypt.org/directory
   # Email address used for ACME registration
   email: ${certmanager_email_address}
   # Name of a secret used to store the ACME account private key
   privateKeySecretRef:
     name: letsencrypt-staging
   # Enable the HTTP-01 challenge provider
   solvers:
   - http01:
       ingress:
         class:  nginx
EOF
}

render_prod_issuer(){
PROD_ISSUER_RESOURCE=$1
cat << 'EOF' > "$PROD_ISSUER_RESOURCE"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
  namespace: cert-manager
spec:
  acme:
    # The ACME server URL
    server: https://acme-v02.api.letsencrypt.org/directory
    # Email address used for ACME registration
    email: ${certmanager_email_address}
    # Name of a secret used to store the ACME account private key
    privateKeySecretRef:
      name: letsencrypt-prod
    # Enable the HTTP-01 challenge provider
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
}

check_os

if [[ "$operating_system" == "ubuntu" ]]; then
  echo "Canonical Ubuntu"
  # Disable firewall 
  /usr/sbin/netfilter-persistent stop
  /usr/sbin/netfilter-persistent flush

  systemctl stop netfilter-persistent.service
  systemctl disable netfilter-persistent.service
  # END Disable firewall

  apt-get update
  apt-get install -y software-properties-common jq
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y  python3 python3-pip
  pip install oci-cli

  # Fix /var/log/journal dir size
  echo "SystemMaxUse=100M" >> /etc/systemd/journald.conf
  echo "SystemMaxFileSize=100M" >> /etc/systemd/journald.conf
  systemctl restart systemd-journald
fi

if [[ "$operating_system" == "oraclelinux" ]]; then
  echo "Oracle Linux"
  # Disable firewall
  systemctl disable --now firewalld
  # END Disable firewall

  # Fix iptables/SELinux bug
  echo '(allow iptables_t cgroup_t (dir (ioctl)))' > /root/local_iptables.cil
  semodule -i /root/local_iptables.cil

  dnf -y update

  if [[ $major -eq 9 ]]; then
    dnf -y install oraclelinux-developer-release-el9
    dnf -y install jq python39-oci-cli curl
  else
    dnf -y install oraclelinux-developer-release-el8
    dnf -y module enable python36:3.6
    dnf -y install jq python36-oci-cli curl
  fi
fi

export OCI_CLI_AUTH=instance_principal
first_instance=$(oci compute instance list --compartment-id ${compartment_ocid} --availability-domain ${availability_domain} --lifecycle-state RUNNING --sort-by TIMECREATED  | jq -r '.data[]|select(."display-name" | endswith("k3s-servers")) | .["display-name"]' | tail -n 1)
instance_id=$(curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance | jq -r '.displayName')

k3s_install_params=("--tls-san ${k3s_tls_san}")

%{ if k3s_subnet != "default_route_table" } 
local_ip=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=src )(\S+)')
flannel_iface=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=dev )(\S+)')

k3s_install_params+=("--node-ip $local_ip")
k3s_install_params+=("--advertise-address $local_ip")
k3s_install_params+=("--flannel-iface $flannel_iface")
%{ endif }

%{ if disable_ingress }
k3s_install_params+=("--disable traefik")
%{ endif }

%{ if install_nginx_ingress }
k3s_install_params+=("--disable traefik")
%{ endif }

%{ if install_traefik2 }
k3s_install_params+=("--disable traefik")
%{ endif }

%{ if expose_kubeapi }
k3s_install_params+=("--tls-san ${k3s_tls_san_public}")
%{ endif }

if [[ "$operating_system" == "oraclelinux" ]]; then
  k3s_install_params+=("--selinux")
fi

INSTALL_PARAMS="$${k3s_install_params[*]}"

%{ if k3s_version == "latest" }
K3S_VERSION=$(curl --silent https://api.github.com/repos/k3s-io/k3s/releases/latest | jq -r '.name')
%{ else }
K3S_VERSION="${k3s_version}"
%{ endif }

if [[ "$first_instance" == "$instance_id" ]]; then
  echo "I'm the first yeeee: Cluster init!"
  until (curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION K3S_TOKEN=${k3s_token} sh -s - --cluster-init $INSTALL_PARAMS); do
    echo 'k3s did not install correctly'
    sleep 2
  done
else
  echo ":( Cluster join"
  wait_lb
  until (curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION K3S_TOKEN=${k3s_token} sh -s - --server https://${k3s_url}:6443 $INSTALL_PARAMS); do
    echo 'k3s did not install correctly'
    sleep 2
  done
fi

%{ if is_k3s_server }
until kubectl get pods -A | grep 'Running'; do
  echo 'Waiting for k3s startup'
  sleep 5
done

%{ if install_longhorn }
if [[ "$first_instance" == "$instance_id" ]]; then
  if [[ "$operating_system" == "ubuntu" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y  open-iscsi curl util-linux
  fi

  systemctl enable --now iscsid.service
  kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/${longhorn_release}/deploy/longhorn.yaml
fi
%{ endif }

%{ if install_nginx_ingress }
if [[ "$first_instance" == "$instance_id" ]]; then
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${nginx_ingress_release}/deploy/static/provider/baremetal/deploy.yaml
  NGINX_RESOURCES_FILE=/root/nginx-ingress-resources.yaml
  render_nginx_config
  kubectl apply -f $NGINX_RESOURCES_FILE
fi
%{ endif }


%{ if ! disable_ingress }
if [[ "$first_instance" == "$instance_id" ]]; then
  install_and_configure_traefik2
fi
%{ endif }

%{ if install_traefik2 }
if [[ "$first_instance" == "$instance_id" ]]; then
  install_and_configure_traefik2
fi
%{ endif }

%{ if install_certmanager }
if [[ "$first_instance" == "$instance_id" ]]; then
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${certmanager_release}/cert-manager.yaml
  render_staging_issuer /root/staging_issuer.yaml
  render_prod_issuer /root/prod_issuer.yaml

  # Wait cert-manager to be ready
  until kubectl get pods -n cert-manager | grep 'Running'; do
    echo 'Waiting for cert-manager to be ready'
    sleep 15
  done

  kubectl create -f /root/prod_issuer.yaml
  kubectl create -f /root/staging_issuer.yaml
fi
%{ endif }

%{ if install_argocd }
if [[ "$first_instance" == "$instance_id" ]]; then
  kubectl create namespace argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/${argocd_release}/manifests/install.yaml

%{ if install_argocd_image_updater }
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/${argocd_image_updater_release}/manifests/install.yaml
%{ endif }
fi
%{ endif }

%{ endif }
