#-----------------------------------------------------------------------
#
# Check input parameters
#
#-----------------------------------------------------------------------
if [ "$#" -ne 1 ]; then
    echo "Illegal number of parameters"
    echo "    rewind.sh <labnumber>"
    echo "where labnumber is between 1 and 8."
    return 5
fi

LABNUMBER=$1

if [ "$LABNUMBER" -lt 1 -o "$LABNUMBER" -gt 8 ]; then

    echo " Lab number should be between 1 and 8"
    return 2
fi


#-----------------------------------------------------------------------
#
# Lab 1 Setup
#
#-----------------------------------------------------------------------
if [ 1 -le "$LABNUMBER" ]; then

echo -e "\nSetting up Lab 1.\n\n"

#
# Checking repo creds and license file
#
if [ ! -f credentials.txt ]; then
    echo " Credentials File is not found!"
    return 2
fi


if [ ! -f license.txt ]; then
    echo "License File not found!"
    return 3
fi


#
#
# Check if logged in
#
echo "Checking if logged into a gcp account..."

OUTPUT=`gcloud auth list --format json`
if [ "$OUTPUT" = "[]" ]; then
    echo "Please log into a valid student account using"
    echo "    gcloud auth login"
    echo "command."
    return 1
fi

echo "A user is logged in."

#
#
# Configure Project Id
#
export PROJECT_ID=`gcloud projects list --format json | jq -r '.[] | select( .projectId | contains("qwiklabs-gcp-") ) .projectId'`


gcloud config set project $PROJECT_ID

export ZONE_ID=`gcloud compute project-info describe --format=json | jq -r '.commonInstanceMetadata.items[] | select( .key== "google-compute-default-zone") | .value'`

gcloud config set compute/zone $ZONE_ID

gcloud config list

#
# VM provisioning 
#

function provision_vm(){

VM=$1

read -r -d '' SPEC << EOT
- name: $VM
  type: compute.v1.instance
  properties:
    zone: $ZONE_ID
    machineType: zones/$ZONE_ID/machineTypes/n1-standard-2
    disks:
    - deviceName: boot
      type: PERSISTENT
      boot: true
      autoDelete: true
      initializeParams:
        sourceImage: projects/centos-cloud/global/images/family/centos-7
    networkInterfaces:
    - network: global/networks/default
      accessConfigs:
      - name: external-nat
        type: ONE_TO_ONE_NAT
EOT


echo -e "$SPEC" 

}

echo -e "#\n# 6 nodes for Edge planet\n#\nresources:" > "edge-6n-spec.yaml"

for i in `seq 1 6`
do
    vm_name=n$i
    echo "provisioning vm: $vm_name"
    provision_vm $vm_name >> "edge-6n-spec.yaml"
    echo "" >> "edge-6n-spec.yaml"
done

gcloud deployment-manager deployments create edge-6n-planet --config edge-6n-spec.yaml


# clean up if things went wrong: 
#   gcloud compute instances delete n1 n2 n3 n4 n5 n6
#   gcloud deployment-manager deployments delete edge-6n-planet

#
echo -e "\nGenerate and setup edge ssh key\n"
#
# generate [once:)]
ssh-keygen -t rsa -f ~/.ssh/edge -C edge -q -N ""

SSH_KEYS=`gcloud compute project-info describe --format=json | jq -r '.commonInstanceMetadata.items[] | select( .key== "ssh-keys") | .value'`
                                                                     
EDGE_SSH_KEY=`cat ~/.ssh/edge.pub | awk '{print "edge:" $1 " " $2  " google-ssh {\"userName\":\"edge\",\"expireOn\":\"2018-12-04T20:12:00+0000\"}"}'`
                                                                                                                                                                                                             
gcloud compute project-info add-metadata  --no-user-output-enabled --metadata-from-file ssh-keys=<( echo -e "$SSH_KEYS\n$EDGE_SSH_KEY" )

#
echo -e "\nSetup ansible configuration"
#
sudo apt-get -y install ansible

mkdir ~/ansible

cat <<EOT >> ~/.ansible.cfg
[defaults]
inventory = ~/ansible/hosts
fork = 50
EOT


for i in `seq 1 6`
do
    export N${i}_IP=`gcloud compute instances describe n$i --zone=$ZONE_ID --format json | jq -r '.networkInterfaces[] .accessConfigs[] | select( .name == "external-nat" ) .natIP'`

    export N${i}_IP_INT=`gcloud compute instances describe n$i --zone=$ZONE_ID --format json | jq -r '.networkInterfaces[].networkIP'`
done



for i in `seq 1 6`
do
    REF_IP=N${i}_IP
    eval NODE_IP=\$$REF_IP
    cat <<EOT >> ~/.ssh/config
Host n$i
    HostName $NODE_IP
    User edge
    IdentityFile ~/.ssh/edge
EOT
done


echo "[edge]" > ~/ansible/hosts
for i in `seq 1 6`
do
    REF_IP=N${i}_IP
    eval NODE_IP=\$$REF_IP
    cat <<EOT >> ~/ansible/hosts
n$i ansible_host=$NODE_IP ansible_user=edge ansible_ssh_private_key_file=~/.ssh/edge
EOT
done

for i in `seq 1 6`
do
    REF_IP=N${i}_IP
    eval NODE_IP=\$$REF_IP
    ssh-keyscan -t rsa $NODE_IP >> ~/.ssh/known_hosts
done

ansible edge -m ping

#

#
## Configure response files
# gen response on local machine
cat <<EOT > edge-response.cfg
IP1="$N1_IP_INT"
IP2="$N2_IP_INT"
IP3="$N3_IP_INT"
IP4="$N4_IP_INT"
IP5="$N5_IP_INT"
IP6="$N6_IP_INT"

IP1_PUBLIC="$N1_IP"
IP2_PUBLIC="$N2_IP"
IP3_PUBLIC="$N3_IP"
IP4_PUBLIC="$N4_IP"
IP5_PUBLIC="$N5_IP"
IP6_PUBLIC="$N6_IP"

HOSTIP="\$(hostname -i)"
MSIP="\$IP1"
ADMIN_EMAIL="opdk@apigee.com"
APIGEE_ADMINPW="Apigee123!"
LICENSE_FILE="/opt/apigee-install/license.txt"
USE_LDAP_REMOTE_HOST="n"
LDAP_TYPE="1"
APIGEE_LDAPPW="Apigee123!"
MP_POD="gateway"
REGION="dc-1"
ZK_HOSTS="\$IP1 \$IP2 \$IP3"
ZK_CLIENT_HOSTS="\$IP1 \$IP2 \$IP3"
CASS_HOSTS="\$IP1:1,1 \$IP2:1,1 \$IP3:1,1"
#CASS_USERNAME="cassandra"
#CASS_PASSWORD="cassandra"
CASS_CLUSTERNAME="Apigee"
PG_MASTER="\$IP4"
PG_STANDBY="\$IP5"
SKIP_SMTP="y"
SMTPHOST="smtp.example.com"
SMTPPORT="25"
SMTPUSER="smtp@example.com"
SMTPMAILFROM="admin@apigee.com"
SMTPPASSWORD="smtppwd"
SMTPSSL="n"
BIND_ON_ALL_INTERFACES="y"
EOT

cat <<EOT > edge-response-setup-org.cfg
IP1="$N1_IP_INT"

MSIP=\$IP1
ADMIN_EMAIL=opdk@apigee.com
APIGEE_ADMINPW="Apigee123!"
NEW_USER="y"
USER_NAME=orgadmin@apigee.com
FIRST_NAME=OrgAdminName
LAST_NAME=OrgAdminLastName
USER_PWD=Apigee123!
ORG_NAME=traininglab
ORG_ADMIN=\$USER_NAME
ENV_NAME=prod
VHOST_PORT=9001
VHOST_NAME=default
VHOST_ALIAS=traininglab-prod.apigee.net
USE_ALL_MPS=y
EOT

cat <<EOT > dev-portal-response.cfg
IP1="$N1_IP_INT"
IP6="$N6_IP_INT"

HOSTIP=$(hostname -i)

MP_POD=gateway
REGION=dc-1

PG_NAME=devportal
PG_USER=apigee
PG_PWD=postgres
PG_HOST=\$IP6

DRUPAL_PG_USER=devportal
DRUPAL_PG_PASS=devportal

DEFAULT_DB=postgres

DEVPORTAL_ADMIN_FIRSTNAME=Training
DEVPORTAL_ADMIN_LASTNAME=Lab
DEVPORTAL_ADMIN_USERNAME=traininglab
DEVPORTAL_ADMIN_PWD=Apigee123!
DEVPORTAL_ADMIN_EMAIL=opdk@apigee.com

EDGE_ORG=traininglab
MGMT_URL=http://\$IP1:8080/v1
DEVADMIN_USER=opdk@apigee.com
DEVADMIN_PWD=Apigee123!

PHP_FPM_PORT=8888

SMTPHOST=smtp.gmail.com
SMTP_PROTOCOL="standard"
SMTPPORT=25
SMTPUSER=
SMTPPASSWORD=
EOT


ansible edge -b -a "yum clean all"
ansible edge -b -a "sudo yum update -y"



ansible edge -b -m yum -a "name=mc state=present"
ansible edge -b -m yum -a "name=nc state=present"
ansible edge -b -m yum -a "name=wget state=present"

ansible edge -ba "mkdir -p /opt/apigee-install"
ansible edge -ba "chown edge:edge /opt/apigee-install"


#
# prerequisites
#


ansible edge -b -m copy -a "src=$PWD/credentials.cfg dest=/opt/apigee-install/"

ansible edge -b -m copy -a "src=$PWD/edge-response.cfg dest=/opt/apigee-install/"

ansible edge -b -m copy -a "src=$PWD/edge-response-setup-org.cfg dest=/opt/apigee-install/"

ansible edge -b -m copy -a "src=$PWD/dev-portal-response.cfg dest=/opt/apigee-install/"

ansible edge -b -m copy -a "src=$PWD/license.txt dest=/opt/apigee-install/"


# visit: http://www.oracle.com/technetwork/java/javase/downloads/jdk8-downloads-2133151.html
# and install: http://download.oracle.com/otn-pub/java/jdk/8u171-b11/512cd62ec5174c3487ac17c61aaa89e8/jdk-8u171-linux-x64.rpm
# http://download.oracle.com/otn-pub/java/jdk/8u181-b13/96a7b8442fe848ef90c96a2fad6ed6d1/jdk-8u181-linux-x64.rpm


wget --no-cookies --no-check-certificate --header "Cookie: gpw_e24=http%3A%2F%2Fwww.oracle.com%2F; oraclelicense=accept-securebackup-cookie" "http://download.oracle.com/otn-pub/java/jdk/8u181-b13/96a7b8442fe848ef90c96a2fad6ed6d1/jdk-8u181-linux-x64.rpm"

ansible edge -m copy -a "src=jdk-8u181-linux-x64.rpm dest=/opt/apigee-install/jdk-8u181-linux-x64.rpm"


fi
#-----------------------------------------------------------------------



#-----------------------------------------------------------------------
#
# Lab 2 Setup
#
#-----------------------------------------------------------------------
if [ 2 -le "$LABNUMBER" ]; then

echo -e "\nRewind to the Lab 2.\n\n"



#
# Lab 2: Prerequisites
# 
ansible edge -b -a "setenforce 0"



ansible edge -bm yum -a "name=/opt/apigee-install/jdk-8u181-linux-x64.rpm state=present"

ansible edge -a "java -version"

fi
#-----------------------------------------------------------------------



#-----------------------------------------------------------------------
#
# Lab 3 Setup
#
#-----------------------------------------------------------------------
if [ 3 -le "$LABNUMBER" ]; then

echo -e "\nRewind to the Lab 3.\n\n"

#
# Define environment variables
#
export REPO_CLIENT_ID=`awk '/User:/{print $2}' $PWD/credentials.txt`
export REPO_PASSWORD=`awk '/Password:/{print $2}' $PWD/credentials.txt`

ansible edge -a "wget https://software.apigee.com/bootstrap_4.18.01.sh -O /opt/apigee-install/bootstrap_4.18.01.sh"

ansible edge -ba "bash /opt/apigee-install/bootstrap_4.18.01.sh apigeeuser=$REPO_CLIENT_ID apigeepassword=$REPO_PASSWORD"


ansible edge -a "/opt/apigee/apigee-service/bin/apigee-service apigee-setup install"



#
# Lab 2: Install Edge
#
ansible n1,n2,n3 -f1 -m shell -a "/opt/apigee/apigee-setup/bin/setup.sh -f /opt/apigee-install/edge-response.cfg -p ds | tee /opt/apigee-install/edge-apigee-ds-install-`date -u +\"%Y-%m-%dT%H:%M:%SZ\"`.log"

ansible n1 -m shell -a "/opt/apigee/apigee-setup/bin/setup.sh -f /opt/apigee-install/edge-response.cfg -p ms | tee /opt/apigee-install/edge-apigee-ms-install-`date -u +\"%Y-%m-%dT%H:%M:%SZ\"`.log"

ansible n2,n3 -f1 -m shell -a "/opt/apigee/apigee-setup/bin/setup.sh -f /opt/apigee-install/edge-response.cfg -p rmp | tee /opt/apigee-install/edge-apigee-rmp-install-`date -u +\"%Y-%m-%dT%H:%M:%SZ\"`.log"

ansible n4,n5 -f1 -m shell -a "/opt/apigee/apigee-setup/bin/setup.sh -f /opt/apigee-install/edge-response.cfg -p sax | tee /opt/apigee-install/edge-apigee-sax-install-`date -u +\"%Y-%m-%dT%H:%M:%SZ\"`.log"

ansible n1 -m shell -a "/opt/apigee/apigee-service/bin/apigee-service apigee-validate install | tee /opt/apigee-install/edge-apigee-validate-install-`date -u +\"%Y-%m-%dT%H:%M:%SZ\"`.log"

ansible n1 -m shell -a "/opt/apigee/apigee-service/bin/apigee-service apigee-validate setup -f /opt/apigee-install/edge-response.cfg | tee /opt/apigee-install/edge-apigee-validate-install-`date -u +\"%Y-%m-%dT%H:%M:%SZ\"`.log"

#
# Firewall rules to expose the planet
#
gcloud compute firewall-rules create edge-ms --direction=INGRESS --priority=1000 --network=default --action=ALLOW --rules=tcp:8080 --source-ranges=0.0.0.0/0

gcloud compute firewall-rules create edge-ui --direction=INGRESS --priority=1000 --network=default --action=ALLOW --rules=tcp:9000 --source-ranges=0.0.0.0/0

fi
#-----------------------------------------------------------------------

#-----------------------------------------------------------------------
#
# Lab 4 Setup
#
#-----------------------------------------------------------------------
if [ 4 -le "$LABNUMBER" ]; then

echo -e "\nRewind to the Lab 4.\n\n"



#
# Lab 3: Provision org and env
# 
ansible n1 -f1 -m shell -a "/opt/apigee/apigee-service/bin/apigee-service apigee-provision setup-org -f /opt/apigee-install/edge-response-setup-org.cfg | tee /opt/apigee-install/edge-apigee-setup-org-install-`date -u +\"%Y-%m-%dT%H:%M:%SZ\"`.log"

gcloud compute firewall-rules create vhost-9001 --direction=INGRESS --priority=1000 --network=default --action=ALLOW --rules=tcp:9001 --source-ranges=0.0.0.0/0

fi
#-----------------------------------------------------------------------


#-----------------------------------------------------------------------
#
# Lab 5 Setup
#
#-----------------------------------------------------------------------
if [ 5 -le "$LABNUMBER" ]; then

echo -e "\nRewind to the Lab 5.\n\n"



#
# Lab 4: DevPortal
# 
ansible n6 -m shell -a "/opt/apigee/apigee-setup/bin/setup.sh -f /opt/apigee-install/dev-portal-response.cfg -p pdb | tee /opt/apigee-install/edge-apigee-devportal-pdb-install-`date -u +\"%Y-%m-%dT%H:%M:%SZ\"`.log"

ansible n6 -m shell -a "/opt/apigee/apigee-setup/bin/setup.sh -f /opt/apigee-install/dev-portal-response.cfg -p dp | tee /opt/apigee-install/edge-apigee-devportal-dp-install-`date -u +\"%Y-%m-%dT%H:%M:%SZ\"`.log"


gcloud compute firewall-rules create devportal --direction=INGRESS --priority=1000 --network=default --action=ALLOW --rules=tcp:8079 --source-ranges=0.0.0.0/0

fi
#-----------------------------------------------------------------------



