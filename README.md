# Redis Enterprise - Build Packer Images for Outscale

This project builds Outscale AMIs for Redis Enterprise using [Packer](https://www.packer.io/) and automates the setup and teardown of the required Outscale infrastructure.

Any runtime specific configuration is setup during the RUN phase, not the build phase, so this image should fit all customer use cases. 

If you want to deploy Redis Enterprise right after the build, you can reuse the settings generated in _my_env.sh in the [OSC-RedisEnterprisePacker-Run](https://github.com/dev-mansonthomas/OSC-RedisEnterprisePacker-Run)

## Requirements
- [Outscale CLI](https://github.com/outscale/oapi-cli) 
- Outscale Account
- [Packer](https://www.packer.io/downloads)
- [jq](https://stedolan.github.io/jq/) (for parsing JSON in shell scripts)
- Tested with BASH 5.x/ZSH on MacOsX

## Download Redis Enterprise

Redis Enterprise tarball must be present in [`redis-software`](redis-software). 
You can download it from [`Redis Cloud`](https://cloud.redis.io), download center in the lower left corner.
Choose the Ubuntu 22.04 version.

## Initial Setup

### Install Packer

```sh
brew tap hashicorp/tap
brew install hashicorp/tap/packer
```

### Outscale Setup

1. **OSC-CLI installation**

If you're using Homebrew : 

```sh
brew tap outscale/tap
brew install outscale/tap/oapi-cli
```
or check other installation methods here : [Github OAPI-CLI](https://github.com/outscale/oapi-cli) 

2. **Authentication Configuration**

Create a new Access Key ID in [Outscale Cockpit](https://cockpit.outscale.com/#/accesskeys)
or Click on your username in the upper right corner of the screen and then click on Access Key.

Add the following keys and values in your shell profile for packer

```sh
export OSC_ACCESS_KEY=...
export OSC_SECRET_KEY=...
```

and create `~/.osc/config.json`file with the following content :

```json
{
  "default": {
    "access_key": "ACCESSKEY",
    "secret_key": "SECRETKEY",
    "region": "eu-west-2"
  }
}
```

Validate that the authentication works by executing the "list VM" call : 

```sh
oapi-cli ReadVms
```

it should answer something similar to : 
```json
{
  "ResponseContext":{
    "RequestId":"a79c959b-c6c0-4087-b687-6b20f2dfc1a5"
  },
  "Vms":[]
}
```

3. **Generate a SSH key pair for outscale**

```sh
oapi-cli --profile default CreateKeypair \
  --KeypairName "outscale-tmanson-keypair"
```

```json
{
  "ResponseContext": {
    "RequestId": "0475ca1e-d0c5-441d-712a-da55a4175157"
  },
  "Keypair": {
    "PrivateKey": "-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----",
    "KeypairType": "ssh-rsa",
    "KeypairName": "outscale-tmanson-keypair",
    "KeypairId": "key-abcdef1234567890abcdef1234567890",
    "KeypairFingerprint": "11:22:33:44:55:66:77:88:99:00:aa:bb:cc:dd:ee:ff"
  }
}
```

Save the `PrivateKey` value in a file `~/.ssh/outscale-tmanson-keypair.rsa` and `chmod 600 ~/.ssh/outscale-tmanson-keypair.rsa`

Replace the \n by linefeed.

In vi you can do this with 

```
:%s/\\n/\r/g
```

## Configuration

Update `_my_env.sh` with (copy the `_my_env_.sh_template` file)
 * `OWNER`            : Who is owner of the Outscale resources created, this will be set in as VPC name and in tag, used by `osc-setup.sh`, ex: `OWNER="thomas-manson"`
 * `REGION`           : Which Region will Redis Enteprise be deployed by `my_instanciate.sh`, ex `REGION=eu-west-2`
 * `REDIS_LOGIN`      : Redis Enterprise administrator login,    used by `my_instanciate.sh`, ex `REDIS_LOGIN=adm@redis.io`
 * `OUTSCALE_SSH_KEY` : Path to the RSA Private Key


## Usage

Note: if you run multiple time `osc-setup.sh` / `tear_down_outscale.sh` / `build_and_deploy_image_with_packer.sh`, remove from `_my_env.sh` the generated values.
If you only rerun `osc-setup.sh` without rebuilding the AMI, keep the `AMI_ID` in the `_my_env.sh`

0. **Ensure your _my_env.sh has all required variables set**

```sh
OWNER="thomas-manson"
OUTSCALE_REGION=eu-west-2
OUTSCALE_SSH_KEY="$HOME/.ssh/outscale-tmanson-keypair.rsa"
```

Run the following scripts in order from the project root:

1. **Provision the Infrastructure:**

   ```sh
   cd osc/
   ./osc-setup.sh
   ```
   
   This will append the following variables to `_my_env.sh` with the various IDs generated during the setup of the VPC

   ```sh
   VPC_ID=vpc-xxx # or NET_ID=vpc-yyyyy for outscale
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
   ./build_and_deploy_image_with_packer.sh outscale
   ```

   This will append the AMI_ID  to `_my_env.sh`
   ```sh
   OUTSCALE_AMI_ID=ami-xyzxyzxyz
   ```

3. **Instantiate an EC2 Instance from the Built Image:**

  See project [OSC-RedisEnterprisePacker-Run](https://github.com/dev-mansonthomas/OSC-RedisEnterprisePacker-Run)

## Notes

- The project uses [`packer/redis_ubuntu_outscale_image.pkr.hcl`](packer/redis_ubuntu_outscale_image.pkr.hcl) as the Packer template.
- Environment variables for resource IDs are stored in `_my_env.sh`.

## TODO
* test renable ufw + firewall=yes in the answer file