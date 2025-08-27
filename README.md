# Redis Enterprise Packer Images on AWS

This project builds AWS AMIs for Redis Enterprise using [Packer](https://www.packer.io/) and automates the setup and teardown of the required AWS infrastructure.

## Requirements

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (configured and authenticated)
- [Packer](https://www.packer.io/downloads)
- [jq](https://stedolan.github.io/jq/) (for parsing JSON in shell scripts)
- Bash shell (tested on Linux/macOS)
- Registered AWS key pair (for SSH access)
- Sufficient AWS permissions to create/delete VPCs, subnets, route tables, security groups, EC2 instances, and AMIs

### Install Packer

```sh
brew tap hashicorp/tap
brew install hashicorp/tap/packer
```

### AWS Credentials Setup

1. **Create a Service Account (IAM User) in AWS Console:**
   - Go to IAM > Users > Add user
   - Assign programmatic access
   - Attach policies: `AmazonEC2FullAccess`, `AmazonVPCFullAccess`, `IAMReadOnlyAccess` (minimum required)
   - Download the Access Key ID and Secret Access Key

2. **Configure AWS CLI:**

```sh
aws configure
```

Example prompts:

```
AWS Access Key ID [None]: XXX
AWS Secret Access Key [None]: YYYY
Default region name [None]: eu-west-3
Default output format [None]: json
```

Update `_my_env.sh` with (copy the `_my_env_.sh_template` file)
 * `OWNER`       : Who is owner of the AWS VPC, this will be set in as VPC name and in tag, used by `aws-setup.sh`, ex: `OWNER="thomas-manson"`
 * `REGION`      : Which Region will Redis Enteprise be deployed by `my_instanciate.sh`, ex `REGION=eu-west-3`
 * `REDIS_LOGIN` : Redis Enterprise administrator login,    used by `my_instanciate.sh`, ex `REDIS_LOGIN=adm@redis.io`
 * `REDIS_PWD`   : Redis Enterprise administrator password, used by `my_instanciate.sh`, ex `REDIS_PWD=redis_adm`

3. **import your ssh public key**

```sh
aws ec2 import-key-pair \
  --key-name tmanson-aws-key \
  --public-key-material fileb://~/.ssh/id_ed25519.pub
```

Add the `KEY-NAME` value (ex: tmanson-aws-key) in `_my_env.sh`
`KEY_NAME=tmanson-aws-key`

4. **Configure your DNS server**

    Let's say you own `paquerette.com` domain, and want to use `aws.paquerette.com` for the Redis Cluster

```sh
aws route53 create-hosted-zone \
  --name aws.paquerette.com \
  --caller-reference "$(date +%s)" \
  --hosted-zone-config Comment="Sous-domaine pour Redis AWS",PrivateZone=false
```

Edit your domaine (here `paquerette.com`) and add the following NS records : 

```
aws 10800 IN NS ns-xx.awsdns-04.net.
aws 10800 IN NS ns-yy.awsdns-34.org.
aws 10800 IN NS ns-zz.awsdns-40.com.
aws 10800 IN NS ns-ww.awsdns-10.co.uk.
```

Ensure, the delegation of aws.paquerette.com is effective using dig : 

```sh
dig NS aws.paquerette.Com

; <<>> DiG 9.10.6 <<>> NS aws.paquerette.Com
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 63644
;; flags: qr rd ra; QUERY: 1, ANSWER: 4, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1232
;; QUESTION SECTION:
;aws.paquerette.Com.		IN	NS

;; ANSWER SECTION:
aws.paquerette.Com.	86400	IN	NS	ns-yy.awsdns-34.org.
aws.paquerette.Com.	86400	IN	NS	ns-ww.awsdns-10.co.uk.
aws.paquerette.Com.	86400	IN	NS	ns-zz.awsdns-40.Com.
aws.paquerette.Com.	86400	IN	NS	ns-xx.awsdns-04.net.

;; Query time: 31 msec
;; SERVER: 192.168.1.254#53(192.168.1.254)
;; WHEN: Fri Jun 13 13:48:16 CEST 2025
;; MSG SIZE  rcvd: 184
```

add 

`CLUSTER_DNS=aws.paquerette.com`

to `_my_env.sh`


## Usage

Run the following scripts in order from the project root:

1. **Provision AWS Infrastructure:**

   ```sh
   cd aws/
   ./aws-setup.sh
   ```

   This will append the following variables to `_my_env.sh` with the various IDs generated during the setup of the VPC

   ```sh
   VPC_ID=vpc-xxx
   IGW_ID=igw-xxx
   RTB_ID=rtb-xxx
   SG_ID=sg-xxx
   SUBNET1=subnet-xxx
   SUBNET2=subnet-xxx
   SUBNET3=subnet-xxx
   AZ1=eu-west-3a
   AZ2=eu-west-3b
   AZ3=eu-west-3c
   ```

2. **Build and Deploy the Packer Image:**

   ```sh
   cd build_scripts/
   ./build_and_deploy_image_with_packer.sh
   ```

   This will append the AMI_ID  to `_my_env.sh`
   ```sh
   AMI_ID=ami-0bc191cbbc5e8392d
   ```


3. **Instantiate an EC2 Instance from the Built Image:**

   ```sh
   cd aws/
   my_instanciate.sh
   ```

   This will append the following variables to `_my_env.sh` with the various IDs generated during the setup of the VPC
   ```sh
   INSTANCE_PUBLIC_IP_1=13.38.11.137 #i-0f3731bccbefe8256
   INSTANCE_PUBLIC_IP_2=51.44.42.52 #i-0570bff1ec77d91bf
   INSTANCE_PUBLIC_IP_3=51.44.4.244 #i-0fe563086da4d41df
   ```

4. **Connect to Your Instance:**

   ```sh
   cd aws/
   connect_to_my_instance.sh 1
   ```

   (Replace `1` with the subnet index if needed.)

## Teardown

When finished, destroy all created AWS resources:

```sh
cd aws/
teardown-aws-vpc.sh
```

---

## Notes

- The project uses [`packer/ubuntu_ufw_aws_image.pkr.hcl`](packer/ubuntu_ufw_aws_image.pkr.hcl ) as the Packer template.
- Redis Enterprise tarball must be present in [`redis-software`](redis-software ).
- Environment variables for resource IDs are stored in `_my_env.sh` (auto-generated).
- All scripts assume the default AWS region is `eu-west-3`.

---

TODO : https://redis.io/docs/latest/operate/rs/references/cli-utilities/rladmin/cluster/join/
* test renable ufw + firewall=yes in the answer file
* gestion des mounts points
* installation scriptée
* Ajout de la license
* internal vs external ip  : https://redis.io/docs/latest/operate/rs/networking/multi-ip-ipv6/
* rackzone awarness: https://redis.io/docs/latest/operate/rs/clusters/configure/rack-zone-awareness/

